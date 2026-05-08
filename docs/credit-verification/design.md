# Credit Verification — Design

> **Version**: 1.0 | **Date**: 2026-05-06
>
> Architecture and algorithm spec for credit verification on hydra. Read [README.md](./README.md) first for the tl;dr; this doc explains the *why* behind every choice.

## Table of contents

1. [Problem statement](#1-problem-statement)
2. [The four tiers](#2-the-four-tiers)
3. [Tier-0: profile audit (the algorithm)](#3-tier-0-profile-audit-the-algorithm)
4. [Defense in depth: the gate's recompute](#4-defense-in-depth-the-gates-recompute)
5. [Event taxonomy](#5-event-taxonomy)
6. [Tier-1: deterministic API path](#6-tier-1-deterministic-api-path)
7. [Tier-2: LLM + native web search](#7-tier-2-llm--native-web-search)
8. [Tier-3: UVN feedback loop](#8-tier-3-uvn-feedback-loop)
9. [Why each design choice](#9-why-each-design-choice-rationale-traceback)

---

## 1. Problem statement

Users submit "credit requests" claiming roles (Mastering, Producer, Lyricist, ...) on Spotify-tracked songs. Muso's risk pipeline scores each request 0–100 and emits per-rule signals (`reject_high_velocity_profile`, `approve_owning_track`, `approve_common_collaborator`, etc.). The bot's job: decide auto-approve / move-to-UVN / escalate-to-human.

**Why "auto-approve" is needed at all.** Humans (Jan, Aaron) can't keep up. The unverified queue depth has been ~20,000 credits at the time of this writing. Auto-approving the obvious wins and routing only the genuinely-ambiguous to humans is what makes credit verification work as a service.

**Why the old system collapsed.** The bot's primary evidence path was *load Tier-1 site in headless Chromium → snapshot rendered text → grep for credited name*. Cloudflare Turnstile started blocking the headless browser around late 2025 / early 2026. By 2026-05, ~50% of Tier-1 fetches failed with timeouts indistinguishable from "browser is down." Production approve rate fell to 3.4% over a 14-day window — 1,253 verdicts and 42 approves, 41 of those from a single 2026-04-22 batch.

The redesign is built around two observations:

1. **Muso's own data has the signal.** A profile with `creditCount=694, popularity=78`, whose unverified credits are 100% Mastering on labels like Spinnin'/Armada/Polydor that the profile has been credited on dozens of times — that's a Bram Fidder pattern. Existing collaboration graph is the strongest single feature available; we don't even need external sources for the obvious wins.

2. **External sources should be JSON APIs, not headless browsers.** MusicBrainz, Spotify, Discogs all have free JSON APIs. ISRC coverage on the unverified queue is 98%. The browser was a 2024-era workaround for "the API doesn't have engineer credits"; that was true when MB was the only candidate, but Discogs is much better for engineer/mastering and we can use the LLM with native web search to fill the gap for the residue.

## 2. The four tiers

Each credit flows through tiers in order until it hits a decision. The expected daily distribution at full volume (~3,000 credits/day):

```
                       Daily queue (~3,000 credits)
                                 │
                       Group by profileId
                                 │
       ┌─────────────────────────┴─────────────────────────┐
       │                                                   │
   profile has ≥20 unverified                       profile has <20 unverified
       │                                                   │
   Tier 0: 8-gate audit                              skip Tier 0
       │                                                   │
   ┌───┴───┐                                               │
   │       │                                               │
  PASS    FAIL                                             │
   │       │                                               │
 BULK    ──┴───────────────────► Tier 1: APIs ◄────────────┘
 APPROVE                              │
                                  ┌───┴───┐
                                  │       │
                                ≥2 srcs  <2 srcs
                                  │       │
                                APPROVE  Tier 2: LLM + web
                                              │
                                          ┌───┴───┐
                                          │       │
                                      ≥2 cite   <2 cite
                                          │       │
                                       APPROVE  Tier 3: UVN
                                                    │
                                            user reply within 30d?
                                              ┌─yes─┴─no─┐
                                              │          │
                                       APPROVE +     REJECT
                                       INGEST graph
                                              │
                                       graph denser → Tier-0 stronger next time
```

| Tier | Purpose | Cost | Throughput |
|---|---|---|---|
| **0** | Profile-level bulk-approve when batch aligns with profile's own approved corpus | 1 admin-API call per profile | ~750/day (~25%) |
| **1** | Deterministic per-credit confirmation via 2+ free APIs by ISRC | free | ~300–600/day |
| **2** | LLM + native web search for credits that didn't pass Tier-1 | LLM tokens (no extra search cost on supported models) | ~300–450/day |
| **3** | UVN: ask user to provide context; ingest reply as new corpus edges | free | residual (~750–900/day initially, shrinks as corpus grows) |

## 3. Tier-0: profile audit (the algorithm)

The entry point: [`profile-audit.sh`](../../workspaces/operations/skills/muso-ops-credit-verification/scripts/profile-audit.sh).

### 3.1 Pseudocode

```python
def audit(profile_id):
    # Fetch unverified queue for this profile (1 admin-API call)
    items = GET("/admin/credit-requests?profilesIds={pid}&status=unverified&limit=1000")

    # G0 — low-volume skip (don't audit profiles with <20 pending; LLM-tier handles them)
    if len(items) < CV_TIER0_MIN_BATCH:               # default 20
        emit "tier0_skipped_low_volume"; return SKIP

    # Pull cc + pop from any item's .profile field (always populated)
    cc, pop = items[0].profile.creditCount, items[0].profile.popularity

    # G1, G2 — profile establishment
    if cc  < CV_TIER0_MIN_CC :  return SKIP            # default 100
    if pop < CV_TIER0_MIN_POP:  return SKIP            # default 50

    # G3, G4 — per-batch sanity
    if industry_fraction(items)      < 0.70: return SKIP  # mostly industry-sourced
    if only_velocity_fraction(items) < 0.70: return SKIP  # only flag is velocity

    # Fetch approved corpus (1 admin-API call)
    approved = GET("/admin/credit-requests?profilesIds={pid}&status=approved&limit=1000")
    if not approved: return SKIP

    # G5 — profile-relative breadth (Sam Feldt fix: legit multi-role artists allowed)
    if max(unv_breadth) > max(ap_breadth) + 1: return SKIP

    # G6 — claimed roles must be a subset of profile's approved roles
    if not unv_roles.issubset(ap_roles): return SKIP

    # G7 — artist co-occurrence
    if artist_overlap(items, approved) < 0.40: return SKIP

    # G8 — label overlap
    if label_overlap(items, approved) < 0.30: return SKIP

    # All 8 pass → emit receipt, dispatcher will use it as the gate's evidence
    receipt = "profile_audit:cc=694,pop=68,batch=50,industry=0.96," \
              "only_vel=1.00,br_max=1/1,roles_ok=1,art=0.96,lbl=0.46"
    emit "tier0_audit_passed" with full structured payload
    return APPROVE_BATCH
```

### 3.2 What each gate exists to kill

Each gate is a real failure mode observed in production data:

| # | Gate | Default | What it kills | Concrete example |
|---|---|---|---|---|
| G0 | `count ≥ 20` | 20 | Per-credit work disguised as bulk | A profile with 5 pending credits goes through Tier-1 instead |
| G1 | `cc ≥ 100` | 100 | Low-establishment fraud | "Ming Vauz" (cc=34, claims 11 roles per track) |
| G2 | `pop ≥ 50` | 50 | Profiles with no Muso popularity score | New accounts gaming the velocity flag |
| G3 | `≥70% industry source` | 0.70 | spclient-scraped batches (lower data quality) | "Roberto Junior" (cc=1365 but 84% spclient) |
| G4 | `≥70% only-velocity` | 0.70 | Compound-fraud batches with multiple negative signals | Multi-flag attacks |
| G5 | profile-relative breadth | +1 | 11-role-bundle fraud | "Ming Vauz" claims Guitar+Piano+Bass+Synth+Lyricist+... per track |
| G6 | `roles ⊆ approved` | strict | Profile drift / role-takeover | A mastering engineer suddenly claiming songwriter |
| G7 | `artist ≥ 40%` | 0.40 | "Spray to all artists" attacks | "Vrancis" (only 18% prior collaborator overlap) |
| G8 | `label ≥ 30%` | 0.30 | Label drift; established profile suddenly on weird labels | Lateral movement attacks |

### 3.3 The receipt format

```
profile_audit:cc=694,pop=68,batch=50,industry=0.96,only_vel=1.00,br_max=1/1,roles_ok=1,art=0.96,lbl=0.46
```

- Always starts with literal `profile_audit:` (gate detects this prefix to route to Tier-0 evidence path)
- Comma-separated `key=value` pairs
- 8–200 chars (matches the gate's existing `--evidence-excerpt` length bounds)
- Self-describing — every gate's value is encoded so the gate can cross-check vs live recompute
- `br_max=N/M` is `unverified_max / approved_max` breadth (pass condition: `N ≤ M+1`)

## 4. Defense in depth: the gate's recompute

The receipt alone isn't trusted. [`muso-admin-api.sh`'s `_tier0_audit_recompute_gate`](../../workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh) runs a parallel evidence path that:

1. **Detects the receipt prefix** (`profile_audit:` → branch into recompute, never falls through to browser-evidence logic)
2. **Re-fetches live data** independent of whatever the audit script saw (separate admin-API calls)
3. **Cross-checks receipt vs live**: `cc` must match exactly; `pop` allowed ±5% drift (configurable via `CV_TIER0_POP_TOLERANCE_FRAC`)
4. **Re-runs all 8 gates from live data** (same algorithm as `profile-audit.sh`)
5. **Accepts only if all 8 pass live**, otherwise emits `tier0_audit_rejected_by_gate` with `reason` field naming which gate failed

Even if the audit script is compromised or the receipt is forged, the gate independently verifies. The gate is the source of truth.

## 5. Event taxonomy

All Tier-0 activity flows through the runlog ([`runlog.sh`](../../workspaces/operations/skills/muso-ops-credit-verification/scripts/runlog.sh)) at `/var/log/openclaw/credit-batch-runs/YYYY-MM-DD/<run_id>.jsonl`. Events emitted by Tier-0:

| Event | Emitter | Trigger | Notable fields |
|---|---|---|---|
| `tier0_audit_passed` | `profile-audit.sh` | All 8 gates passed | `profile_id`, `receipt`, `creditCount`, `popularity`, `batch`, `industry`, `only_velocity`, `unverified_max_breadth`, `approved_max_breadth`, `artist_overlap`, `label_overlap` |
| `tier0_audit_verified` | gate's `_tier0_audit_recompute_gate` | Gate independently re-verified | `profile_id`, `receipt`, `live_cc`, `live_pop` (and full live recompute snapshot) |
| `action_attempted` | `batch-verify-profile.sh --tier0` | Successful PUT to admin API | `profile_id`, `action: "approve"`, `cr_ids[]`, `count`, `evidence_kind: "tier0_profile_audit"`, `evidence_excerpt` (= the receipt) |
| `tier0_profile_passed` | dispatcher | Final per-profile success marker | `profile_id`, `credits_approved` |
| `tier0_skipped_low_volume` | `profile-audit.sh` | `count < CV_TIER0_MIN_BATCH` | `profile_id`, `unverified_count`, `min_batch` |
| `tier0_skipped_gate_fail` | `profile-audit.sh` | One of G1-G8 failed | `profile_id`, `failed_gate`, `actual_value`, `threshold` |
| `tier0_skipped_no_corpus` | `profile-audit.sh` | Profile has zero approved credits | `profile_id`, `unverified_count` |
| `tier0_profile_fell_through` | dispatcher | Audit exited 1 (skip); credits stay in queue for B2 | `profile_id` |
| `tier0_audit_rejected_by_gate` | gate | Receipt cross-check OR live recompute failed | `profile_id`, `receipt`, `reason` (e.g., `cc_mismatch`, `g7_artist_overlap`) |

### Important coupling

Three downstream gates had to be updated because Tier-0 is a fundamentally new evidence path:

- **`runlog.sh` cookie-cutter detector** — exempted for `evidence_kind=tier0_profile_audit`. Receipts ARE structurally similar across profiles (`profile_audit:cc=...`); without exemption, the second Tier-0 approve in a run would be flagged as silent-failure.
- **`browser-evidence-audit.sh`** — accepts a Tier-0 anchor: a decision event with `evidence_kind=tier0_profile_audit` is grounded if a matching `tier0_audit_verified` event exists for the same `profile_id` AND `receipt` strings match.
- **`compute-run-summary.sh`** — counts Tier-0 `action_attempted` events under `approved_attempted`. Reconciliation works correctly because the gate emits both the receipt and the audit_verified event before `action_attempted` lands.

## 6. Tier-1: deterministic API path

For credits that don't go through Tier-0 (small-volume profiles, or profiles that fail Tier-0 gates), drop into per-credit API verification.

| Source | Endpoint | Auth | Hit rate (estimated) | Status |
|---|---|---|---|---|
| **MusicBrainz** | `/ws/2/recording/?query=isrc:<ISRC>&inc=artist-credits+artist-rels` | none | ~5–7% on the queue | Helper deployed |
| **Spotify Web API** | `/v1/tracks/{id}` (by ISRC or trackId) | OAuth client credentials | ~100% (every credit has spotifyTrackId) | Helper deployed, awaits `SPOTIFY_CLIENT_ID/SECRET` |
| **Discogs** | `/database/search?q=<artist+title>` then `/releases/{id}.extraartists` | free token | ~30–50% (estimated) for engineer/mastering | Helper not yet built (awaits token) |

The Tier-1 rule: ≥2 sources confirm name + role → APPROVE. Same quorum semantic as the existing browser-evidence gate (`CV_REQUIRED_LOADS=2`), just deterministic.

### Why MusicBrainz hit rate is low

The unverified queue skews indie / recent / non-Western (Mexico, Brazil, Finland, Thailand, Germany, Austria — small labels, late 2024+ releases). MB's ISRC index is comprehensive for major-label catalog but patchy for this long tail. A 30-credit sample showed 2/30 ISRCs in MB; verified directly that the misses really aren't there. **Don't overweight MB** — it's free and deterministic, but Discogs and Spotify will carry more of the load.

### Why Spotify Web API matters

100% coverage on the queue (every credit row has `spotifyTrackId`). Confirms canonical artists, ISRC, label. Useful for "Recording Artist" / "Performer" claims. Doesn't expose engineer/mastering — those credits aren't in Spotify's public API.

### Why Discogs matters most for this queue

Top claimed roles in the unverified queue: Producer (38%), Mixing (28%), Mastering (28%), Composer (26%), Engineer (24%). Discogs is the strongest API for engineer/mastering — its release pages have detailed `extraartists` arrays.

## 7. Tier-2: LLM + native web search

For credits that fail Tier-1 (no API confirmation), the LLM steps in with native web search.

The key insight: **don't load search engines in headless Chromium** (Cloudflare Turnstile blocks it). Use OpenRouter's `web` plugin via `extra_body`:

```json
{
  "model": "openai/gpt-5.5",
  "messages": [...],
  "plugins": [
    { "id": "web", "engine": "native", "max_results": 5 }
  ]
}
```

`engine: "native"` is the magic value — it routes to the model's built-in web search tool (Anthropic Claude 4+ and OpenAI gpt-5+ both have one). No extra cost beyond model API tokens. Returns citations as inline Markdown URLs in the response text. **Note:** `engine: "auto"` is documented but rejected by OpenRouter's API as of 2026-05-06; only `"native" | "exa" | "firecrawl" | "parallel"` are accepted.

Openclaw passes this through via `extra_body` config:

```bash
openclaw --profile main config set 'agents.list[6].params.extra_body' \
  '{"plugins":[{"id":"web","engine":"native","max_results":5}]}' --strict-json
```

(See [operations.md § Configuring Tier-2](./operations.md#configuring-tier-2) for the full setup.)

The Tier-2 evidence rule: ≥2 distinct citation domains in the model's response with the credited name + role/track context.

### Known blocker

Openclaw exposes `web_search` as a local tool function (with no provider configured because there are no Brave/Exa/Tavily keys). The model calls openclaw's local `web_search` first because it's in the tool list, gets `"web_search disabled"`, and improvises. To unblock, drop `web_search` from the operations agent's tool list (`agents.list[6].tools.deny`). Then only the OpenRouter plugin path remains. See [lessons.md § OpenRouter local-tool collision](./lessons.md#172-openrouter-web-search-smoke-test-was-a-false-positive).

## 8. Tier-3: UVN feedback loop

Future work. Pseudocode:

1. Credit lands in UVN
2. Bot DMs the credit owner: "We couldn't auto-verify. Could you share one of: a Spotify/Apple/Tidal URL where your name appears in credits, a collaborator we can confirm with, a project file, the label release contact?"
3. User reply → approve credit + ingest into corpus:
   - Add new edges to user's collaboration graph
   - Add label to approved-label set
   - Future Tier-0 audits for this profile see the new evidence
4. 30-day TTL: no reply → auto-reject

Each confirmed UVN response makes Tier-0 stronger for that profile next time. The system learns each user's professional network from their own confirmations. After ~6 months of operation, fewer credits should need UVN as the corpus densifies.

## 9. Why each design choice (rationale traceback)

### Why profile-level decisions, not per-credit?

A 46+8854 labeled-set grid search showed per-credit rules max out at **~11.6% precision** at any reasonable recall. The signal that actually discriminates is profile-level (`creditCount + popularity + role-consistency-with-profile`). Profile-level audit + per-credit fallback is dramatically more precise than per-credit alone. The stacked AND of 8 gates effectively compounds precision.

### Why a hand-tuned formula instead of ML?

For v1: interpretability and tunability matter more than 5% precision gains. A hand-tuned linear formula with explicit thresholds:
- Auditable — Jan/Aaron can read "approved because cc=694, art=0.96, lbl=0.46" and reason about it
- Tunable — single number changes
- Cold-start — works on day 1 without a labeled corpus

Once the system has produced ~1,000 decisions with downstream Jan/Aaron approve-or-reject ground truth, a logistic regression with the same features is the natural progression. The features stay; the weights become learned.

### Why 8 gates and not 3 or 15?

Empirically grid-searched. Each gate cuts a real failure mode without adding much false-negative cost. Removing any one of G1/G2/G3/G4/G5/G6/G7/G8 lets a known-fraud-class profile slip through (verified against real rejected samples on the system).

### Why bash and not Python?

Existing skill scripts are bash + jq (`runlog.sh`, `batch-verify-profile.sh`, `count-approvals.sh`, `compute-run-summary.sh`, `preflight-verify.sh`). Adding Python would mean (a) a new dependency on the gateway runtime, (b) two languages for new contributors to learn, (c) breaking the bats-test pattern that everything in the dir already uses. Bash + jq is awkward but consistent.

### Why deterministic bash loop instead of LLM iteration?

First dry-run: bot read SKILL.md prose about Tier-0, executed it for 1 profile, then bailed on B2. The LLM treats new SKILL.md prose as optional. Mechanical bash for-loop iterates ALL eligible profiles before the LLM gets involved. The LLM cannot selectively skip what it doesn't see. This is the "feedback_llm_instruction_insufficient" principle: prose is hint, code is enforcement.

### Why defense-in-depth recompute in the gate?

The audit script and the gate are independently shippable code paths. If a future SKILL.md change accidentally bypasses `profile-audit.sh`, or if a forged receipt is submitted, the gate's recompute catches it. The cost is one extra admin-API call per Tier-0 approve — cheap. The benefit is "the gate is the source of truth" stays a true statement even if the audit script gets compromised.

### Why drop browser at all?

Browser is the cause of (a) Cloudflare blocks, (b) 15-min run timeouts, (c) the B2 stall observed in production dry-runs, (d) ~250 lines of plugin enforcement that exists *only* because browser keeps producing bad evidence (Cloudflare HTML shells, stale tabs). All of browser's jobs in credit verification have better paths now (API for Tier-1, native LLM web search for Tier-2). The only real loss is AllMusic (no public API), and AllMusic is reachable indirectly through Google's cached snippets via native web search.

This isn't *removing* browser from the agent — it's just removing browser from the *credit-verification* evidence path. The browser plugin remains available for refund-processing, intercom CS, and other ops flows where rendering a real page matters.
