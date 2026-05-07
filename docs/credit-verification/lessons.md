# Credit Verification — Lessons + Changelog

> **Version**: 1.0 | **Date**: 2026-05-06
>
> Engineering lessons surfaced while building credit verification, plus a chronological log of significant changes. Read before re-touching the gate, jq pipelines, or the SKILL.md prose. For the "why" behind the architecture, see [design.md](./design.md); for runbook, see [operations.md](./operations.md).

## Table of contents

1. [Engineering lessons](#1-engineering-lessons)
2. [Changelog](#2-changelog)
3. [Outstanding work](#3-outstanding-work)
4. [Recommended next iteration](#4-recommended-next-iteration)

---

## 1. Engineering lessons

Each one ate at least 5 minutes of debug time on 2026-05-06. Worth memorizing.

### 1.1 jq `index(.)` rebinds `.` inside pipes

**Symptom:** `label_overlap` returned 1.00 in a test where 23/25 unverified labels were "Random Label N" (not in approved set). Should have been ~0.08.

**Root cause:** This jq looks correct but isn't:

```jq
[$per[] | select(. != "" and ($labelset | index(.) != null))]
```

Inside `($labelset | index(.))`, the `.` is rebound to the input of that subexpression — which is `$labelset` itself (an array). `index($labelset)` does subsequence search and finds the array trivially at position 0, so `index(.) != null` is true for every element.

**Fix:** explicit `as $cur` binding:

```jq
[$per[] | . as $cur | select($cur != "" and ($labelset | index($cur) != null))]
```

**Principle:** any time you pipe into a function that takes its input from `.`, bind the outer iteration value with `as $name` first. The `.` inside `(... | f(.))` refers to whatever was on the left of the pipe, NOT the surrounding `[]` iteration.

This is the third time the same pattern has bit us (see hydra memory `reference_jq_any_scoping_gotcha.md`). Add a lint pass for `index(.)` and `any(...; ... .)` on jq pipelines.

### 1.2 jq `--argjson` exceeds `ARG_MAX` on large data

**Symptom:** `profile-audit.sh ea30c1ef-...` (Sam Feldt: 91 approved × 13 roles each) failed with `/usr/bin/jq: Argument list too long`. Linux `ARG_MAX` is ~128 KB on most distros.

**Root cause:** `--argjson unv_items "$LARGE_JSON"` puts the entire JSON on the command line.

**Fix (two-part):**

1. Derive small "facts" objects (lists of strings, scalar counts) ONCE via stdin-piped jq, then `--argjson` only those small derived facts.
2. Where original code passed full UNVERIFIED_ITEMS, expose a `labels_per_credit` / `artists_per_credit` flat list inside `facts_unverified` and use that instead.

**Principle:** `--argjson` is fine for small data, fatal for big. Always project to a small derived facts object before re-passing as arg. The same fix had to be applied in two places (`profile-audit.sh` G8, `muso-admin-api.sh` `_tier0_audit_recompute_gate` G8) — both had the same algorithm copied across.

### 1.3 `set -e` + bash function returning 1 inside `var=$(fn ...)` silently exits the script

**Symptom:** `--requester clio` made `muso-admin-api.sh` exit silently — no stderr, no useful return code. It happened DURING arg parsing, before reaching the gate.

**Root cause:** `resolve_slack_to_email "clio"` returned 1 (because "clio" isn't an `@` email and wasn't a known synthetic). The parser had:

```bash
REQUESTER_EMAIL=$(resolve_slack_to_email "$2")
```

With `set -euo pipefail`, a function returning 1 inside `$(…)` of a global `var=…` assignment causes the script to exit. `local var=…` doesn't (because `local` always returns 0 on its own line), but the parser used a global assignment.

**Fix (two-part):**

1. Whitelist `clio` in `resolve_slack_to_email` (return the input unchanged for known synthetic identities, exit 0).
2. Defense in depth: `REQUESTER_EMAIL=$(resolve_slack_to_email "$2") || REQUESTER_EMAIL="$2"`.

**Principle:** `VAR=$(fn ...)` (without `local`) inside `set -euo pipefail` is a silent-exit landmine. Always either guard with `|| true` / `|| fallback`, or use `local`, or split into `out=$(fn) && VAR=$out`. **In a script that has hundreds of users, every bash assignment via command-substitution is a potential silent-exit.**

### 1.4 Deploy hygiene: scp dest path mismatch

**Symptom:** `--tier0` flag rejected with "unknown argument" even though local tests passed. The deployed `batch-verify-profile.sh` was the OLD one; the new copy ended up at the wrong path.

**Root cause:** `scp` of multiple files to a generic destination dir, followed by a `mv` step that assumed both ended up in `scripts/`. Only one of them did.

**Fix:** explicit per-file scp dest, and ALWAYS verify deployed file content with a deterministic check before assuming the deploy succeeded:

```bash
scp ... source.sh root@host:/full/explicit/path/source.sh
ssh ... "grep -c 'expected_unique_string' /full/explicit/path/source.sh"
```

If the count doesn't match the local count, deploy didn't take.

**Principle:** trust nothing on the deploy step. The cost of verifying is one ssh round-trip; the cost of believing a successful scp + broken behavior is hours of debugging the wrong layer.

### 1.5 LLM doesn't reliably follow new SKILL.md prose

**Symptom:** First dry-run after adding §B1.6 — bot read SKILL.md (we saw it grep for `B1.6|tier0|profile-audit.sh`) but then went straight to B2 and only audited 1 profile via Tier-0 before bailing on B2's broken browser path.

**Root cause:** The bot's "B0-B1 bash blob" is the canonical recipe it executes verbatim. Adding NEW prose elsewhere in SKILL.md doesn't reliably get incorporated into that blob. The LLM treats new optional steps as optional.

**Fix:** Move the Tier-0 loop INTO the canonical bash blob (B1.6 in §B1.6 prose now contains the actual `for pid in $(... | awk '$1>=20 {print $2}'); do bash batch-verify-profile.sh --tier0 ...; done` loop). Bash iterates ALL eligible profiles before the LLM does anything. The LLM cannot selectively skip.

**Principle:** This is `feedback_llm_instruction_insufficient` — prose is hint, code is enforcement. Any new step that needs to fire reliably must be deterministic bash, not LLM-prose. Today is the third time this principle has paid off in this codebase.

### 1.6 Adding a new "approval path" means thinking about every downstream check

**Symptom:** First dry-run completed Tier-0 mechanically (50 credits dry-approved), but `post-batch-summary.sh` refused to post with `Failure 1 shape — queue_depth>0 AND action_attempted==0`.

**Root cause:** Tier-0 dispatcher emitted `tier0_profile_passed` but NOT `action_attempted`. Compute-run-summary and post-batch-summary both check for `action_attempted` events; absence triggers Failure 1 refusal. Even after we wired `action_attempted` emission, two more downstream gates also needed updates: cookie-cutter detector (would flag identical Tier-0 receipts) and browser-evidence audit (demands Tier-1 anchor for every decision event).

**Fix:** dispatcher now emits `action_attempted` with `evidence_kind=tier0_profile_audit, action=approve, cr_ids=[...], count=N` after a successful PUT. Cookie-cutter detector exempted for that evidence_kind. Browser-evidence audit accepts the event as grounded if a matching `tier0_audit_verified` exists.

**Principle:** any new `action_attempted` shape means auditing every gate that reads `action_attempted`. We found three (cookie-cutter, browser-evidence audit, post-batch-summary). For future new evidence paths, search the codebase for every `select(.event == "action_attempted")` and `grep '"event":"action_attempted"'` reader before declaring done.

### 1.7 Subagent "smoke test passed" can be a false positive

**Symptom:** A subagent earlier in the session reported "OpenRouter native web search smoke test SUCCESS" with a Discogs URL in the response. Later investigation revealed the model didn't actually use OpenRouter's plugin — it called `exec curl` directly to hit the Discogs API and improvised the citation, because openclaw's local `web_search` tool returned `web_search disabled` and the model worked around it.

**Root cause:** "Citations appeared in the response" doesn't mean "OpenRouter plugin worked." The model can produce URLs from prior context, model knowledge, or improvised tool calls. A real smoke test needs to inspect the actual evidence path: did the URL come from a `citations[]` field on the response, or from a model-improvised `exec` call?

**Fix:** validation by trace, not by output. Have the validator inspect the trajectory for the specific signal:

```bash
jq -c 'select(.message.role=="toolResult" and .message.toolName=="web_search")' \
  /root/.openclaw-main/agents/operations/sessions/<id>.jsonl
```

If that's empty AND the response has URLs, the model improvised — the plugin path didn't fire.

**Principle:** subagent reports are claims. Verify with the trace — especially when the success criterion is "X happened" rather than "X output appeared". Output is downstream of mechanism; testing only output lets mechanism failures slip through.

### 1.8 OpenRouter plugin: `engine: "auto"` is documented but rejected

**Symptom:** First config attempt used `engine: "auto"` (per the OpenRouter docs UI). OpenRouter API returned `400 plugins.0.engine: Invalid option: expected one of "native"|"exa"|"firecrawl"|"parallel"`.

**Root cause:** `auto` is documented in OpenRouter's web UI as the dropdown's default value; the API itself only accepts the four explicit values. Likely a UI / API drift on OpenRouter's side.

**Fix:** use `engine: "native"` explicitly. Both gpt-5.5 and Claude 4.6 Sonnet support native search; `"native"` does what `"auto"` was intended to do.

**Principle:** when integrating with a third-party API, prefer explicit values over defaults. UI docs aren't always API contract.

### 1.9 openclaw 2026.5.5 shell tool is named `exec`, not `bash`

**Symptom:** `lib/api-evidence.sh::count_profile_api_evidence` always returned 0 in production. Bats fixtures used `name=="bash"` and passed; the live session JSONLs used `name=="exec"` so the jq filter never matched real invocations. Discovered when tailing a live session at 08:53 UTC and seeing `"name":"exec"` on every shell call.

**Root cause:** openclaw 2026.5.5 names its shell tool `exec` in session JSONLs at `/root/.openclaw-main/agents/<agent>/sessions/*.jsonl`. Earlier convention (and some test fixtures) used `bash`. The schema accepts the old name in some places, so writing fixtures with `bash` doesn't fail any check — until the live filter doesn't match anything.

**Fix:** `select(.name=="exec" or .name=="bash")` in any jq pipeline that scans shell calls. Production-truth name is `exec`; the alias keeps tests portable.

**Principle:** when fixtures and production diverge on tool names, both should pass. Verify with a real session JSONL before committing a filter that depends on a name. One-line sanity check:
```bash
jq -r 'select(.message.content[]?.type=="toolCall") | .message.content[]?.name' \
  /root/.openclaw-main/agents/operations/sessions/*.jsonl | sort -u
```

### 1.10 Apostrophes in comments inside single-quoted jq scripts terminate the heredoc

**Symptom:** `lib/api-evidence.sh` failed with `bash: line 143: syntax error near unexpected token \`$lines[]'\``. Line 143 was `(reduce ($lines[] | ...` — perfectly valid jq, but bash refused to parse it.

**Root cause:** the jq filter was wrapped in a single-quoted bash heredoc (`jq '... script ...'`). A comment several lines up read `# OpenClaw's shell tool is named "exec"...`. The apostrophe in `OpenClaw's` closed the bash quote. Bash then interpreted the remaining jq lines as code.

**Fix:** plain English in jq comments. `OpenClaw's` → `The OpenClaw`. `don't` → `do not`. Single-quote-safe by construction. `bash -n` after editing catches it immediately because parsing fails before runtime.

**Principle:** bash single quotes have no escape mechanism. Anything between `'…'` is literal except for closing `'`. Multi-line jq filters wrapped in `'…'` are landmines; alternatives are heredoc with `<<'JQ'` (delimiter quoted means no interpolation, apostrophes are safe) or `--from-file <(cat <<'JQ' ... JQ)`.

### 1.11 Three credit-verification gates must move in lockstep on CV_EVIDENCE_MODE

**Symptom:** During the 2026-05-07 cutover live test, the agent correctly invoked Tier-1 (MB) + Tier-2 (got `vuproductions.gr` citation), but the approve attempt got `rejected_pre_flight: missing_profile_browse`. 196 retries before the agent gave up and bulk-UVN'd the rest. Root cause: I'd only made TWO of THREE evidence gates `CV_EVIDENCE_MODE`-aware.

**Root cause:** there are three gates in the credit-verification approve path, each with its own evidence-quorum check:

1. `muso-admin-api.sh::enforce_credit_approve_gate` (the bash gate the API call passes through)
2. `runlog.sh` event-write gate (refuses `verdict_without_evidence`)
3. `batch-verify-profile.sh` pre-flight (browse-required + quorum, runs *before* the API call)

I patched (1) and (2) to consult `lib/api-evidence.sh` under `CV_EVIDENCE_MODE=api`, but (3) still called the old browser-only `count_profile_browser_loads` and `count_excerpt_matches`. Result: every Tier-1+Tier-2 approve attempt died at gate (3) before reaching gate (1) which would have accepted it.

**Fix:** PR #260 commit `239a2d6` added the `CV_EVIDENCE_MODE` dispatch to `batch-verify-profile.sh` too — sources both libs, picks the count function based on mode, mirrors the pattern used in (1) and (2).

**Principle:** before changing the evidence model, list every gate that consults it. Grep is mandatory:
```bash
grep -rn 'count_profile_browser_loads\|count_excerpt_matches\|browser-evidence' workspaces/operations/skills/ scripts/
```
Three gates, three patches, one PR. Missing one means "the system rejects evidence for the right reason in the wrong gate."

### 1.12 The agent will pattern-match cron job names to `openclaw cron run` if SKILL.md doesn't explicitly forbid it

**Symptom:** Nick @-mentioned the bot with `run credit verification batch`. SKILL.md §Step 0 says this should fire **Batch Mode (B1–B5) inline** in the current session. Instead the agent ran `openclaw cron --help` → `cron show 081a0d98-...` → `cron run 081a0d98-... --expect-final --timeout 1800000` against the cron job named `credit-verification-batch-4h`. The cron run was rejected by openclaw 2026.5.5 schema (separate bug — cron payload still on `agentTurn` instead of `systemEvent`) and silently went nowhere; agent posted "Starting it now…" to Slack but no batch ran.

**Root cause:** the agent's reconnaissance found a cron job named "credit-verification-batch-4h" and pattern-matched the user's "run credit verification batch" to "fire that cron job". The original SKILL.md prose said run B1-B5 inline but didn't *forbid* the cron-delegate path, so the agent inferred delegation was acceptable. (The agent's stated reasoning even said "I'll let the batch post its normal `[HEARTBEAT-BATCH]` summary back here when it finishes" — perfectly plausible if the cron run actually worked.)

**Fix:** explicit `⚠️ DO NOT delegate to openclaw cron run` block at SKILL.md §Step 0 (commit `bb1b63f`). Spells out: "Run Batch Mode" means invoke the workflow scripts directly from this session; if you find yourself reading `cron-jobs.json` or running `openclaw cron --help` while handling an @-mention, you have taken the wrong turn.

**Principle:** if there's a plausible alternative path that the SKILL.md doesn't explicitly forbid, the agent will eventually take it. Prose like "do X" doesn't preclude "also do Y" — agents bias toward action they can justify. When two paths could plausibly satisfy a directive, name the wrong one and reject it explicitly.

### 1.13 `bats` 1.13 silently passes failing `[[ ]]` assertions when followed by another assertion

**Symptom:** A test with three `[[ ]]` assertions in a row passed locally on bats 1.13.0 but failed on node-8 with bats 1.10.0. The middle assertion's substring was missing from the actual output; both bats versions ran the same code; only the harness behavior differed.

**Root cause:** bats 1.13's test runner appears to evaluate intermediate `[[ … ]]` exit codes non-strictly when followed by another assertion that succeeds. bats 1.10 evaluates strictly — every failed `[[ ]]` fails the test. So a test asserting:
```bash
[ "$status" -eq 7 ]
[[ "$output" == *"no successful browser load found"* ]]   # FALSE in reality
[[ "$output" == *"$PID"* ]]                                # TRUE — PID is in output
```
…passes on 1.13 (final assertion succeeded) but fails on 1.10 (middle assertion failed).

**Fix:** assert against substrings actually present in the new error message. The test was checking for legacy prose ("no successful browser load found") that I'd refactored to mode-aware text ("no successful Tier-1 browser snapshot" or "no successful evidence source"). Switched to the mode-independent `verdict_without_evidence` label.

**Principle:** local bats green ≠ CI bats green. Confirm assertions actually fire by inverting one and watching it fail. Don't assume `[[ ]]` short-circuits to test failure — explicit `&& failure_message; false` is more portable. And: hot-patched live runs are a good final integration test that fixtures aren't enough on their own.

---

## 2. Changelog

### 2026-05-07 — Cutover deployed (PR #260)

**Shipped the documented 4-tier pipeline end-to-end.** The browser-removal work proposed on 2026-05-06 (originally scoped at 1 week per §3.1 below) compressed to one session of hot-patches + one PR.

**Built and deployed:**

- `lib/api-evidence.sh` (replacement for `lib/browser-evidence.sh`) — counts API helper hits + native web_search citation domains. 19 bats tests.
- `discogs-isrc-lookup.sh` (third API helper, gated on `DISCOGS_TOKEN` per #255). 12 bats tests.
- Three credit-verification gates made `CV_EVIDENCE_MODE`-aware in lockstep: `enforce_credit_approve_gate` (`muso-admin-api.sh`), runlog.sh verdict gate, `batch-verify-profile.sh` pre-flight. `api` is the default, `browser` remains as the rollback knob.
- openclaw config: `agents.list[6].params.extra_body.plugins[{id:"web", engine:"native", max_results:5}]` + `tools.deny += ["web_search"]` (drops the local web_search shadow tool — see §1.8).
- Three browser-forcing plugin hooks deleted: `block-web-fetch-tier1`, `redirect-web-search`, `block-escalation-without-browse`. Surviving hooks: `mark-cv-session`, `block-unsanctioned-batch-message`, `cleanup-session-state`.
- `browser-evidence-audit.sh` short-circuits the browser-anchor check under `api`-mode (the bash + runlog gates already enforce evidence per decision).
- AllMusic browser fallback removed entirely (commit `e655dfe`) after AllMusic went offline ("being updated") mid-test and Discogs `web_fetch` hit Cloudflare. Browser is no longer a sanctioned source under api-mode.
- SKILL.md: top-level "EVIDENCE MODEL — 2026-05-06 CUTOVER" block, mandatory api-first preamble at §3α with explicit bash commands, explicit `⚠️ DO NOT delegate to openclaw cron run` rule at §Step 0 (see §1.12).

**Test totals after deploy:** 633 bats tests across the impacted surface, 633 pass.

**Live verification (four runs in one session):**

- `20260506-202031-675159` — pre-cutover; gates correctly refused 73 unsupported UVNs.
- `20260507-085537-c83be3` — surfaced the `exec` vs `bash` tool-name bug (§1.9, fixed mid-run in commit `e0d2710`).
- `20260507-120856-5a2337` — first end-to-end Tier-1+Tier-2 hit (`vuproductions.gr` cited for Nasos Nomikos); surfaced the three-gate lockstep gap (§1.11, fixed mid-run in commit `239a2d6`).
- `20260507-133229-7dd133` — clean 4-min run, 0 errors, 0 browser/web_fetch attempts, 0 cron delegations, Tier-0 cleared 91 credits + 30 UVN flags. Tier-2 still skipped by the agent (deferred follow-up — see §3.1 below).

**Bugs caught and fixed:** five new lessons added above (§1.9–1.13).

### 2026-05-06 — Tier-0 ships, browser-removal proposed

**Built and deployed today (in one session, ~12 hours):**

- `profile-audit.sh` (Tier-0 8-gate auditor) + 15 bats tests
- `batch-verify-profile.sh --tier0 --profile-id <pid>` mode + 13 bats tests
- `enforce_credit_approve_gate` Tier-0 evidence path with defense-in-depth recompute (`muso-admin-api.sh`) + 9 bats tests
- `musicbrainz-isrc-lookup.sh` (Tier-1 helper, free, no auth) + 9 bats tests
- `spotify-track-lookup.sh` (Tier-1 helper, awaits creds) + 9 bats tests
- `runlog.sh` cookie-cutter exemption for `evidence_kind=tier0_profile_audit`
- `browser-evidence-audit.sh` Tier-0 anchor recognition + 4 bats tests
- `SKILL.md` §B1.6 with deterministic Tier-0 bash loop; B2 updated to consume `$B2_QUEUE_JSON`
- `OPS_TIER0_ENABLED=1` added to `/etc/openclaw/main.env`
- OpenRouter `web` plugin configured at `agents.list[6].params.extra_body` (Tier-2 prep)
- `resolve_slack_to_email` accepts `clio` (synthetic identity for the bot)

**Test totals after deploy:** 611 bats tests, 609 pass, 2 pre-existing baseline failures unrelated.

**Live verification:**

- Manual smoke test: 5 profiles audited correctly (3 PASS, 2 FAIL on G1/G3, 1 SKIP)
- Dry-run #1 (`20260506-171316-57e0d9`): 50 credits dry-approved on Alpha Mastering, bot bailed on B2; surfaced action_attempted and browser-evidence audit gaps
- Dry-run #2 (`20260506-183759-fd57ee`): 79 credits dry-approved (Alpha Mastering + new profile afc2a143), deterministic loop confirmed, summary blocked downstream by browser-evidence audit (B2 incomplete; expected behavior given browser still drives B2)

**Bugs caught and fixed:** seven, listed above in [§1 Engineering lessons](#1-engineering-lessons).

### Pre-2026-05-06 history

For diagnostic detail, see also `/Users/nick/.claude/plans/ok-explain-to-me-modular-hamster.md` (Parts I and II) — the original "what's broken" research that prompted this work, plus the prescriptive ship plan.

Key milestones referenced there:

- 2026-04-22: 41-credit auto-approve burst (the only meaningful approve volume in 14 days; everything else was UVN/escalate)
- 2026-04-21: 317 approves blocked by gate (PR #132 model-bump regression; reverted same day in PR #142)
- 2026-04-29: Tier-2 approval gate added (incident response)
- 2026-05-04: Spotify dropped from Tier-1 (login-gated for headless)
- 2026-05-05: INCONCLUSIVE_TIER1_UNREACHABLE verdict ladder default changed from per-credit-escalation to UVN
- 2026-05-06: Bram Fidder incident triggers this redesign

---

## 3. Outstanding work

In priority order:

### 3.1 (high) Make agent actually exercise Tier-2 — #259

**Status:** infrastructure shipped 2026-05-07 (PR #260) but live runs show the agent goes MB-miss → bulk-UVN, skipping Tier-2 entirely. 0 web_search attempts across 2 batches of fall-through profiles. The system is *safe* (everything goes to humans) but throughput is degraded — Tier-2 should be clearing ~10–15% of the queue per [design.md:81](./design.md).

**Why the prose alone isn't enough:** SKILL.md §3α step 2 explicitly tells the agent to ask the model to research before UVN-flagging. The agent reads it, sometimes acknowledges it ("Tier-2 uses the LLM's native web search via OpenRouter plugin"), then UVN-flags anyway. The safe-default attractor (UVN rather than risk a bad approve) dominates.

**Recommended fix (per #259):** mechanical Tier-2-attempt gate in `batch-verify-profile.sh` flag path. Refuse UVN flag for fall-through profiles unless the session contains evidence of a Tier-2 attempt for the credit (an assistant message that names the credited person AND has either a search-hint phrase or ≥1 URL). This forces the agent through the path without forcing approval — it can still UVN-flag, it just has to *try* first.

**Out of scope for this iteration:** Tier-2 quality (citation reputation, snippet quality). That's a tightening task once the path is firing.

### 3.2 (medium) Cron job schema migration — `payload.kind="systemEvent"`

**Status:** the autonomous 4-hourly `credit-verification-batch-4h` cron fires but openclaw 2026.5.5 rejects with `Error: main cron jobs require payload.kind="systemEvent"`. The cron job in `cron-jobs.json` still has `payload.kind="agentTurn"`. This was missed in the 2026.5.5 schema migration (commit `26d22f4`).

**Why it didn't surface earlier:** manual @-mention triggers (`run credit verification batch`) take a different code path that doesn't hit the cron schema. So the inline Batch Mode flow works fine; only the autonomous 4-hourly cron auto-fire is silently skipped.

**Fix:** edit the cron job's payload to:
```json
"payload": { "kind": "systemEvent", "text": "run credit verification batch" }
```
(Drop `model`, `thinking`, `fallbacks`, `timeoutSeconds` — those come from the agent's own config under `sessionTarget=main`. The agent already has the model + extra_body wired since 2026-05-07.)

**Estimated effort:** 5 minutes + reload via `openclaw cron update <id>`. File a separate issue if not done before the next autonomous run is needed.

### 3.3 (medium) Runlog verdict gate's `profile_id`-empty bypass

**Status:** during run `20260507-120856-5a2337`, 202 verdict events were written with `profile_id: null`. The runlog gate at `runlog.sh:236` only fires when `[[ -n "$pid" ]]`, so all 202 verdicts bypassed the api-evidence check. The bash gate (`enforce_credit_approve_gate`) caught the corresponding actual API calls — but only because they had non-null payloads. Verdicts as a separate event type are unguarded.

**Fix:** make the runlog gate fail-closed on empty `profile_id`. Refuse the verdict with a clear remediation message ("verdict events must carry profile_id"). One-line edit + bats coverage.

### 3.4 (medium) Cookie-cutter detector ISRC-anchored fabrication shape

**Status:** the existing cookie-cutter gate refuses ≥3 verdicts with byte-identical `.reason` text. During `20260507-120856-5a2337` the agent embedded each unique `cr_id` in the reason text, breaking byte-identity, and got 142 verdicts citing the same single MB result through. Same fabrication shape as the 2026-05-04 incident the gate was supposed to catch — just dressed in api-mode clothing.

**Fix:** strengthen the detector to also flag when ≥N verdicts cite the same ISRC string, MB recording id, or "MusicBrainz lookup" anchor phrase. ~5-line jq edit in `runlog.sh`.

### 3.5 (medium) B6 EXIT trap so summary always posts

Add an EXIT trap on the B0-B1 bash blob:

```bash
trap '_summary_on_exit "$RUN_ID" "$PARENT_MSG_TS"' EXIT
```

Where `_summary_on_exit` calls `compute-run-summary.sh --final` and `post-batch-summary.sh` regardless of how the bash blob exits. Even when B2 stalls, the run gets a closing summary with a `:warning: B2 incomplete` banner.

Required: `post-batch-summary.sh` needs to gracefully handle "Tier-0 succeeded, B2 incomplete" instead of hard-refusing. Add `--allow-partial`, OR change the audit to refuse only if Tier-0 itself has uncovered profiles (not B2 leftovers).

**Estimated effort:** 30 min including bats tests.

### 3.6 (low) UVN feedback loop (Tier-3)

Future work; not on the critical path for this iteration. See [design.md § 8 Tier-3](./design.md#8-tier-3-uvn-feedback-loop) for the scoping.

### 3.7 (low) Provision API tokens for Discogs (#255) + Spotify (#256)

`discogs-isrc-lookup.sh` and `spotify-track-lookup.sh` are shipped + tested but inert (exit 4: creds_missing). Once tokens land, the Tier-1 quorum becomes 2-source on its own (MB + Discogs, or MB + Spotify) without needing Tier-2 — partially mitigates §3.1 too.

---

## 4. Recommended next iteration

The 2026-05-07 cutover shipped what was prescribed below. The next iteration's goal is now **getting the agent to actually use Tier-2** (§3.1).

### Iteration goals

1. ~~Browser no longer drives credit verification~~ — done 2026-05-07
2. ~~Tier-2 web search actually fires~~ infrastructure-wise — but agent doesn't invoke it (§3.1)
3. Mechanical Tier-2-attempt gate → agent forced through Tier-2 before UVN
4. Real-mode batch: ≥10% of fall-through credits clear via Tier-2 citations

### Sequencing (dependency-respecting parallel)

- **Track A** (1 day): mechanical Tier-2-attempt gate (§3.1). Add `count_profile_tier2_attempts` to `lib/api-evidence.sh`; require ≥1 attempt in `batch-verify-profile.sh` flag path before allowing UVN. Bats coverage. Hot-patch live; observe one cron cycle.
- **Track B** (parallel, 30 min): cron schema migration (§3.2). One config write + `openclaw cron update`.
- **Track C** (parallel, 1 day): runlog `profile_id`-empty fail-closed (§3.3) + cookie-cutter ISRC-anchor detector (§3.4). Both small jq edits + bats tests.
- **Track D** (parallel, 30 min when scheduled): Discogs / Spotify token provisioning (#255, #256). Removes the dependency on Tier-2 since Tier-1 alone reaches quorum once two API helpers fire.

### Done criteria

- Real-mode batch: 200 credits fetched, Tier-0 clears trusted profiles, Tier-1 API + Tier-2 LLM-search clears more, residue goes to UVN.
- Slack summary shows: `Tier-0: N profiles, M credits | Tier-1 API: K credits | Tier-2 LLM+web: J credits | UVN: U credits | Errors: 0`.
- Jan/Aaron spot-check 5 random Tier-0 approves; all correct.
- ≥10% of non-Tier-0 credits clear via Tier-2 citations (matches design.md throughput target).
- Production approve rate climbs from ~3.4%/day toward the design.md target of ~25% via Tier-0 alone + 10–15% via Tier-2 = ~40% on the eligible queue.
