# Credit trust: the tool-less model ladder and fetched-source evidence (T01)

Every AI step of the credit trust system (web credibility, the document-forensics reviewer,
Caroline's drafts, the Ops decision, the digest summary) goes through one provider ladder with one
audit ledger. Fable design 2026-10-15, ticket T01.

Code: `scripts/credit_trust/` (`llm.py`, `ledger.py`, `websearch.py`, `credibility.py`),
`scripts/lib/codex-judge-exec.sh`, CLI `scripts/credit-trust.py`.
Tests: `python3 scripts/tests/test_credit_trust_llm.py` (CI: py-tests job).

## The ladder: $0 first

| Rung | What | Cost | Used for |
|---|---|---|---|
| 1. codex | vendored `codex exec`, tool-less (below), on the ChatGPT subscription OpenClaw already holds. Model `gpt-6.1-sol`, then `gpt-6-sol` | $0 | every step |
| 2. jev | `scripts/lib/jev.sh`, TypeSafe direct (Q2 ruling), typed questions over an evidence packet | TypeSafe plan (recorded as unknown, not $0) | evidence combination only: no web, no images. The decider calls it when Codex is unavailable; its answer can only mean support or defer, never approve |

`Provider.judge(prompt, schema, images=[], web=False, step=..., jev_questions=None)` tries the rungs
in order and returns the first usable answer. Every attempt (served, failed or skipped) is one row.

**No paid rung.** The ladder has no OpenRouter rung. The one metered path is the credit_review
OpenRouter judge as `FetchedSourcesJudge`'s fallback. For `credit-review.py decide` it runs only with
`--paid-fallback`, wrapped in `decide.CappedJudge`, which is the single owner of the per-run cap and the
captain's shared **$25/day** verifier cap (counted across the credit-review ledger).

**Codex model.** gpt-6.1-sol replaced the retired gpt-5.5 on 2026-10-14. On the codex-cli 0.156.1
pinned with openclaw 2026.8.35, the backend refuses it with 400 "The 'gpt-6.1-sol' model is not
supported when using Codex with a ChatGPT account"; it needs the 0.161 client. The ladder asks for it
first, falls back to `gpt-6-sol` on that exact refusal, and remembers the refusal for 6h. Override
with `CREDIT_TRUST_CODEX_MODEL` / `CREDIT_TRUST_CODEX_FALLBACK_MODEL`.

## Why the Codex rung is safe to feed attacker-controlled text

The judge reads claims, profile names, web pages and user documents. It is therefore **never an
OpenClaw agent turn**, which has `exec`. `codex-judge-exec.sh` runs one direct model call:

- **Tools off.** `--disable shell_tool` plus every tool-bearing feature: unified_exec, apps,
  plugins, browser/computer use, image generation, multi-agent, hooks, code_mode_host and the rest.
- **Sandbox.** `-s read-only`, an empty `-C` work dir, `--ignore-user-config`, `--ignore-rules`,
  approval `never`, structured output via `--output-schema`.
- **Prompt on stdin, never in argv.** `/proc/<pid>/cmdline` is world-readable.
- **Credentials.** A throwaway tmpfs `CODEX_HOME` (`/run/hydra-judge`) holds an **access token
  only**. The refresh slot carries the `SYNC-MANAGED-NO-REFRESH-TOKEN` sentinel, the same pattern as
  `codex-quota-probe.sh`, so the single-refresher invariant holds. Before anything is reported, the
  helper re-checks that the credential was not rewritten and that the real refresh token is nowhere
  in the scratch tree. On a failure it exits rc 9 and writes the kill switch
  `/etc/hydra/credit-trust-codex.disabled`.
- **Unprivileged user.** The model runs as `hydra-judge`, created by `deploy.sh`; the helper refuses
  to run it as root. `/root` is 0700, so a root-owned read-only copy of the vendored codex tree is
  staged under `/var/lib/hydra-judge/codex/<size-mtime>/`.
- **Rollout census.** The helper checks the session rollout, not the `--json` summary. A tool call
  that was not refused is rc 4, and the answer is discarded. That is also why it does not pass
  `--ephemeral`: the rollout lives in the tmpfs scratch home and is shredded with it.
- **Quota guard.** The helper reads the measured row for the active account
  (`/var/lib/hydra/codex-usage/*.measure.tsv`). If the account is `unknown` (never measured, stale or
  lapsed) or its load is above 80%, the rung is skipped. It never rotates accounts.

## T01 spike (node-8, 2026-10-15, codex-cli 0.156.1)

- **The tool-less call works.** gpt-6-sol: 11-21 s, 8k-32k input tokens, $0. `codex-auth-invariants.sh
  --check` and `ensure-codex-auth.sh --check` were clean after every run.
- **There is no headless web search.** codex has no `--search` flag. `-c web_search="live"` makes
  every model (gpt-6-sol, gpt-6-luna, gpt-5.6-sol) call **Code Mode's JS `exec` tool**
  (`tools.web__run(...)`). That tool needs the uninstalled `codex-code-mode-host` and is an
  interpreter surface, so it stays off and those calls fail closed ("code-mode host is disabled").
  The attempts appear **only in the rollout**; the `--json` stream showed just the final message.
  The `code_mode.*` config keys are ignored on 0.156.1.
- **Without search the models invent sources.** Asked who mixed "Birds of a Feather", the answers
  varied by run: gpt-6-luna and gpt-5.6-sol said Rob Kinelski, each with confident Tidal / Apple /
  AllMusic URLs. MusicBrainz credits Jon Castelli and Aron Forbes. Model-written URLs are never
  evidence; they are counted in `uncited_urls`.
- **The retro scout's 103 "web lookups" (credit-retro-hold-docfraud-f1 §4) do not contradict this.**
  - Its runner was `codex exec --skip-git-repo-check -s read-only` with the **shell tool on** and no
    `web_search` setting.
  - Its URLs were "model-reported … I did not fetch all of them".
  - That fits the spike: the CLI did not search, and the answers came from model memory with
    unverifiable URLs.
  - The live decider does not use that runner. It is an exec surface on attacker-controlled text, and
    its citations cannot be checked.
- **Images.** `-i` attaches document images. The helper copies them into the scratch dir so the
  judge user can read them.

## Web credibility at $0: we search and fetch, Codex judges

Codex cannot search, so search and judging are split (firstmate 001):

1. **Search and fetch, server-side** (`websearch.Searcher`, $0):
   - **MusicBrainz:** the recording by ISRC, else by title + artist. It skips live, remix and Atmos
     recordings and keeps the ones that carry credits. Their artist relationships (mix, producer,
     engineer, instrument) are rendered deterministically.
   - **Wikipedia:** the track's own article, with the lead/infobox and the Personnel section kept.
   - **Optional engines:** SearXNG if `CREDIT_TRUST_SEARXNG_URL` is set, Brave API if
     `BRAVE_SEARCH_API_KEY` is set. Neither exists today.
   - **Blocked:** DuckDuckGo html/lite, Mojeek and Brave HTML answer node-8's OVH address with a
     captcha or 429.
   - **Fetching** is SSRF-guarded: public addresses only, the socket dials the address that was
     checked (no DNS rebinding), redirects re-checked, no proxy (`HTTP(S)_PROXY` is ignored), bodies
     capped.
   - **Snapshots.** Every body is kept content-addressed at
     `/var/lib/hydra/credit-trust/snapshots/<sha256>.json` (0600).
2. **Judging.** Tool-less Codex reads numbered `SOURCES` (S1..Sn). Each finding is `{source_id,
   quote, says, effect}`.
3. **Verification** (`credibility.verify_findings`). A finding survives only when its quote (≥ 12
   chars, case/space/quote-folded) is verbatim in that source's fetched text. Kept findings carry the
   URL, the snapshot sha256 and the quote. Invented sources and quotes are dropped and recorded in
   `dropped_findings`.
4. **Fallback.** If nothing can be fetched, or Codex is unavailable, the OpenRouter web-plugin judge
   (grok-4.3) runs under the caller's cap, if the caller gives one. The decider gives none by default:
   with no source it does not call the model, and if a source fetch failed it defers the row.

`FetchedSourcesJudge` has the credit_review judge interface, so
`credit-review.py audit|review|eval --provider codex` uses it with the policy unchanged. A finding
counts only if its exact page is cited, and big tracks never approve on web evidence alone.

**Known limit.** MusicBrainz and Wikipedia are crowd-edited, so a confirmation from them is a
citation, not proof. The existing clamps (two independent domains, no web-only approval on big
tracks, red flags hold) still apply, and the decider never approves on a supporting set made only of
crowd-edited domains. T07/T08 should add edit-recency checks before any approval leans on them.

### High-risk big-track fixture: two 2026-10-14 claims

| Claim | Sources fetched | Codex verdict | Verified quote |
|---|---|---|---|
| Claim 1: Keyboard on a pop-88 track | Wikipedia | REJECT-RECOMMENDED 0.91 | the personnel section credits the claimant with mixing and other people with keyboards |
| Claim 2: Producer on a pop-83 track | MusicBrainz ×2, Wikipedia | REJECT-RECOMMENDED 0.96 | the article credits a different producer for the session |

Even a model APPROVE with verified quotes is clamped on a big track. The unit test
`HighRiskBigTrackFixture` locks that in, with an anonymous claimant ("Claimant A").

### Labelled eval (90 rows: 60 stillfloo known-bad, 30 trusted-confirmed known-good), $0

Run on node-8 2026-10-15 22:0xZ with `credit-review.py eval --provider codex`. Same labelled set as
the h1 grok-4.3 eval. **Full** arm: trusted catalog credits visible. **Blind** arm: withheld, so the
web evidence must carry the decision.

| judge | arm | mode | flag precision / recall | CONTRADICTED·REJECT precision (recall) | CONFIRMED·APPROVE precision (recall) | APPROVE on known-bad | $ |
|---|---|---|---|---|---|---|---|
| Codex gpt-6-sol on fetched sources | full | audit | 1.00 / 1.00 | 1.00 (0.517) | 1.00 (1.00) | - | 0 |
| Codex gpt-6-sol on fetched sources | blind | audit | 0.882 / 1.00 | 1.00 (0.133) | - (0) | - | 0 |
| Codex gpt-6-sol on fetched sources | full | review | 1.00 / 0.533 | 1.00 (0.533) | 1.00 (0.833) | **0** | 0 |
| Codex gpt-6-sol on fetched sources | blind | review | 1.00 / 0.133 | 1.00 (0.133) | - (0) | **0** | 0 |
| x-ai/grok-4.3 web plugin (h1, 10-11) | full | audit | 0.966 / 0.95 | 1.00 (0.70) | 1.00 (0.933) | - | $22.3/1k |
| x-ai/grok-4.3 web plugin (h1, 10-11) | blind | audit | 0.779 / 1.00 | 1.00 (0.617) | 1.00 (0.267) | - | $32.6/1k |

**Run stats:** 246 Codex calls, 0 model errors, 6.9 s and 9.6k input tokens on average, $0. The me.com
weekly quota stayed at 6%.

**The T01 bar is met:** CONTRADICTED precision 1.00, every one with a verified quoted citation;
0 approve recommendations on known-bad; audit flag recall 1.00.

**Weaker than grok on coverage.** Blind CONTRADICTED recall is 0.13 against grok's 0.62, and blind
CONFIRMED recall is 0 against 0.27. MusicBrainz and Wikipedia simply do not list most of these
tracks' engineers.

**Ladder decision for the web-credibility step:**
1. Codex on fetched sources first ($0).
2. A claim it cannot decide stays NEEDS-HUMAN / SUSPECT, never approved.
3. OpenRouter grok-4.3 under the $25/day cap (`decide.CappedJudge`) is the opt-in fallback when
   nothing can be fetched or Codex is down.

**Coverage paths.** Recall rises when a general search engine is available that does not captcha
node-8. Either deploy SearXNG (an H-DevOps change) or approve a Brave Search API key, then set its
env var.


## Ledger: `/var/lib/hydra/credit-trust/ledger.sqlite3`, table `llm_calls`

Each row records:
- `ts`, `step`, `provider`, `outcome` (ok / error / skipped), `reason`, `model`;
- `prompt_sha256` (sha256 of the exact UTF-8 prompt) and `schema_sha256`;
- tokens, `cost_usd` (0 on the subscription), `latency_ms`, engine-only `citations_json`,
  `uncited_urls`;
- `meta_json`: the codex argv, account, version, run-as user, safety verdict and tool census;
- `raw_path`: a 0600 file with the prompt, schema, answer and metadata. Re-hash the prompt to check
  the row.

SQLite triggers refuse UPDATE and DELETE. Case events link to a row by `llm_call_id`. The
credit_review `judge_json` now also records `prompt_sha256`, `llm_call_id`, `provider`, `sources`
and `dropped_findings`.

## Operating it

```bash
# one call through the ladder, or one rung; prints argv/safety for codex
python3 /opt/hydra/scripts/credit-trust.py llm-probe --provider codex
python3 /opt/hydra/scripts/credit-trust.py llm-probe --provider codex --web     # re-check headless search after a codex bump
# one claim, fetched sources + Codex (read-only)
python3 /opt/hydra/scripts/credit-trust.py web-check --person "<claimant name>" --role Keyboard \
  --title "<track title>" --artist "<primary artist>" --pop 88
python3 /opt/hydra/scripts/credit-trust.py llm-calls --limit 20
```

**Switches.**
- `/etc/hydra/credit-trust-codex.disabled` stops the Codex rung. It is written automatically on a
  credential-safety violation.
- `/etc/hydra/codex-quota-probe.disabled` also skips the rung, because quota is unknown.
- `CREDIT_TRUST_CODEX_WEB=1`: only after `llm-probe --provider codex --web` shows a `web_search_call`
  in the rollout and no Code Mode `exec`.
