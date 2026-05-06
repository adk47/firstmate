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

---

## 2. Changelog

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

### 3.1 (high) Drop browser as the credit-verification primary path

**Why:** browser is the cause of (a) Cloudflare blocks, (b) 15-min run timeouts, (c) the B2 stall observed in production dry-runs, (d) ~250 lines of plugin enforcement that exists *only* because browser keeps producing bad evidence. All of browser's jobs in credit verification have better paths now.

**What:**

1. Get `SPOTIFY_CLIENT_ID` / `SPOTIFY_CLIENT_SECRET` propagated from k8s secrets into `/etc/openclaw/main.env` (already in `audit/.../analytics.yaml`)
2. Get a Discogs developer token (https://www.discogs.com/settings/developers, 30s, free); add as `DISCOGS_TOKEN`
3. Drop `web_search` from operations agent's `tools.deny` list — leaves OpenRouter plugin as only path. Smoke-test by triggering a web-search probe and verifying citations come back as inline Markdown URLs (not via openclaw's tool channel)
4. Update SKILL.md B2 prose: replace "load Tier-1 site via browser" with "call `tier1-api-verify.sh` (deterministic) then LLM tail with native search for the gap"
5. Update `enforce_credit_approve_gate` to count "≥2 distinct API confirmations OR ≥2 distinct citation domains" as evidence equivalent to "≥2 distinct Tier-1 browser hosts"
6. Archive `plugins/muso-credit-verification-enforcer/src/hooks/block-web-fetch-tier1.ts` and `redirectWebSearch.ts` — no longer needed
7. Run a third dry-run; expect Tier-0 + Tier-1 + Tier-2 to all fire cleanly

**Estimated effort:** 1 week of work, mostly deletions. Most risky step is #5; has the most existing test coverage to update.

### 3.2 (high) Tier-2 web search local-tool collision fix (subset of 3.1)

Just step 3 above. ~5 minutes + smoke test. Unblocks OpenRouter native search even before the rest of the browser-removal work.

### 3.3 (medium) B6 EXIT trap so summary always posts

Add an EXIT trap on the B0-B1 bash blob:

```bash
trap '_summary_on_exit "$RUN_ID" "$PARENT_MSG_TS"' EXIT
```

Where `_summary_on_exit` calls `compute-run-summary.sh --final` and `post-batch-summary.sh` regardless of how the bash blob exits. Even when B2 stalls, the run gets a closing summary with a `:warning: B2 incomplete` banner.

Required: `post-batch-summary.sh` needs to gracefully handle "Tier-0 succeeded, B2 incomplete" instead of hard-refusing. Add `--allow-partial`, OR change the audit to refuse only if Tier-0 itself has uncovered profiles (not B2 leftovers).

**Estimated effort:** 30 min including bats tests.

### 3.4 (medium) Cron task investigation — `credit-verification-batch-4h` last status `skipped`

Pre-existing issue (memory entry suggests intermittent for a while). Not blocked by today's work. Worth a 30-min dig before relying on autonomous 4-hourly runs.

### 3.5 (low) UVN feedback loop (Tier-3)

Future work; not on the critical path for this iteration. See [design.md § 8 Tier-3](./design.md#8-tier-3-uvn-feedback-loop) for the scoping.

---

## 4. Recommended next iteration

If/when committing to "drop browser, ship the rest":

### Iteration goals

1. Browser no longer drives credit verification (remains available for other ops flows)
2. Tier-2 web search actually fires
3. Summary always posts (even on B2 partial)
4. Real-mode test: 1 profile (Alpha Mastering) approved via Tier-0 in production, Jan/Aaron spot-check

### Sequencing (dependency-respecting parallel)

- **Track A** (1 day): drop `web_search` from operations agent's tools.deny; smoke-test OpenRouter native search; verify citations come back; add `tier2-citations-extract.sh` parser helper
- **Track B** (2 days, parallel with A): EXIT trap in B0-B1 bash blob; `post-batch-summary.sh --allow-partial` mode; bats tests; fresh dry-run that posts even when B2 incomplete
- **Track C** (after A+B): rewrite `enforce_credit_approve_gate` evidence-counting; replace browser-snapshot grep with API-confirmation + citation-domain counter; test updates; SKILL.md B2 prose rewrite
- **Track D** (after C): archive browser-tier1 enforcer hook; remove browser-evidence-audit's tier1 path; full bats sweep
- **Track E** (parallel, 30 min when scheduled): Discogs token + smoke-test `discogs-isrc-lookup.sh`

### Done criteria

- Real-mode batch: 200 credits fetched, Tier-0 clears the trusted profiles bulk, Tier-1 API + Tier-2 LLM-search clears more, residue goes to UVN
- Slack summary shows: "Tier-0: N profiles, M credits | Tier-1 API: K credits | Tier-2 LLM+web: J credits | UVN: U credits | Errors: 0"
- Jan/Aaron spot-check 5 random Tier-0 approves; all are correct
- No "browser tool unavailable" Slack messages for 7 consecutive days
- Production approve rate climbs from ~3.4%/day to >40%/day on the eligible queue
