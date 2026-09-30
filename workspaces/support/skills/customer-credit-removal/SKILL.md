---
name: customer-credit-removal
description: Autonomously remove credits a customer owns from their own profile, OR detect mis-described unmerge requests and escalate them with audit context
triggers:
  - "remove these tracks"
  - "remove this track"
  - "remove this credit"
  - "delete this credit"
  - "these aren't my tracks"
  - "these aren't mine"
  - "not my songs"
  - "wrong tracks on my profile"
  - "tracks aren't mine"
  - "take this off my profile"
  - "you merged the wrong profile"
  - "split this back out"
  - "unmerge"
---

# Customer Credit Removal (self-service)

## Purpose

Two related customer requests, handled together:

**Capability A – track removal**: customer says "remove these tracks from my profile," lists tracks that don't belong, expects them gone. Mechanical, high-volume, low blast radius. Caroline **executes autonomously** for the verified owner of the profile.

**Capability B – unmerge-mistake triage**: customer says the same thing, but what's actually happened is two distinct artists were merged into one profile – removing tracks won't fix it because they'll re-appear on the next ingest. Caroline **detects this case, gathers context, and escalates** to Operations via `action-request` (tier 2). She does NOT execute the unmerge – that's Aaron-approved only.

Both share the same ownership-check chain.

## What this skill does NOT do

- Remove tracks from a profile the requester doesn't own (refuses)
- Add credits, merge profiles, change profile metadata (out of scope)
- Execute an unmerge directly (escalates to Aaron via action-request)
- Operate on unclaimed profiles (refuses – routes to action-request for human handling)
- **Role-based removal** ("remove all my Keyboard credits", "drop the Producer role from these tracks but keep my Composer credit"). The underlying DELETE endpoint removes ALL of the profile owner's roles on the (track, profile) pair – it can't surgically drop one role and keep others. If the customer asks to remove a specific role across tracks, file `action-request` with `actionType: bulk-credit-change` (tier 2) and let ops handle it via a different admin path. Recognizable shape: any request that says "all my X credits" / "everything with role Y" / "drop the X role" rather than naming specific tracks.

## Tools this skill uses

- `profile_status` – read the target profile. Returns `{found, profile:{id, name, verified, isClaimed, primary_role, credits_count, workspaces:[{email,isClaimed}], knownAsNames}, latest_credits[3], latest_credit_date}`. The `isClaimed`, `workspaces`, and `knownAsNames` fields drive the Step-2 ownership check. Already allowlisted.
- `credits_search` – read the credits on the profile (paginate with `limit=100` if the profile has more credits than fit in one page). Already allowlisted.
- `create_ticket` – escalate capability-B unmerge-mistake cases as tier-2 `unmerge-request`. Already allowlisted.
- `remove_credits` – the typed wrapper around the deletion script. Caroline does NOT use raw `exec`; this tool is the only way to issue a DELETE. The script independently re-verifies ownership, runs the Intercom-email cross-check, and refuses on any production-side role on the matched track – so `remove_credits` is its own security boundary, not just a thin call site.

`remove_credits` does its OWN independent ownership check + audit logging inside the underlying bash script. Caroline's ownership check (Step 2 below) is the first line of defense; the tool re-verifies independently as the second line.

## Flow

### Step 0 – Bail-out check (runs before every other step on every turn)

Some customer messages signal that the right move is to hand off to a teammate, NOT to keep trying tools. Check the latest customer message AND the conversation arc before doing anything else.

**Explicit human-request triggers** (case-insensitive, fuzzy on common variants):
- "talk to a human", "speak to someone", "speak to a manager", "speak to a person", "real person", "actual person"
- "I want a human", "let me speak to support", "escalate this", "get me someone"
- "are you a bot", "is this a bot", "is this AI", "are you AI"

**Frustration / loop signals** (any one is enough):
- Profanity directed at the agent ("this is bullshit", "fucking useless", etc.)
- "this is ridiculous", "this is frustrating", "I'm done with this", "wasting my time"
- Customer has restated the same complaint twice with no progress (Caroline's replies haven't unblocked them)
- 3+ back-and-forth rounds without a successful tool call resolution

**Action when ANY of the above fires:**

1. Stop the current flow. Do NOT call `remove_credits` or any other write-side tool.
2. Call `create_ticket` with:
   - `actionType: "support-general"`
   - `customerEmail`: the email from `[CONVERSATION_CONTEXT]`
   - `summary`: 1-line description of what the customer was originally trying to do
   - `conversationSummary`: 2-3 sentence summary including the bail-out reason
   - `details`:
     ```json
     {
       "escalation_reason": "customer_requested_human" | "frustration_detected" | "loop_detected",
       "original_ask": "<what they were trying to do, plain English>",
       "conversation_excerpt": "<verbatim last ~3 customer turns, redact obvious PII>"
     }
     ```
3. Reply to the customer:

   > "Sorry this has been frustrating – I've passed you over to one of our teammates, they'll pick this up shortly."

4. Stop. Do not keep proposing fixes or asking clarifying questions. The teammate will take over.

**Why this is Step 0**: per `feedback_llm_instruction_insufficient.md`, prose at the bottom of a skill rarely fires. Putting the bail-out at the top makes it the first thing Caroline checks on every conversation turn.

### Step 1 – Parse the customer message

Extract:
- `profile_uuid` from the URL in the message (or from `[CONVERSATION_CONTEXT]`)
- `tracks[]` – list of "Artist - Title" lines the customer wants removed
- `intercom_email` from `[CONVERSATION_CONTEXT]`

If profile_uuid is missing, ask:

> "Could you share the URL of the profile you want me to remove these from? It looks like `https://credits.muso.ai/profile/<uuid>`."

If tracks list is missing or unclear, ask for it explicitly. Do NOT guess what the customer wants removed.

If `intercom_email` is missing from `[CONVERSATION_CONTEXT]` (the extractor sometimes fails on edge-case message shapes – see `plugins/intercom/src/extractors.ts`), do NOT proceed and do NOT ask the customer for their email – a self-declared email is exactly the verification gap this skill is built to avoid. Instead, file via `action-request` (tier 2, `action_type: credit-correction`) with:

> "Want to get this sorted for you – I've passed it to our team and they'll follow up shortly."

The verified email property of `intercom_email` is load-bearing for the entire skill. If Intercom didn't give us one, the safe path is human review.

### Step 2 – Ownership verification (hard gate)

Call `profile_status` for `profile_uuid`. The wrapper script will re-verify independently as the load-bearing gate, so this Caroline-level check is a fast-fail UX optimization – it lets the customer-facing reply tell them WHY before invoking the deletion path. The wrapper is the actual security boundary.

When ownership fails, ALSO compute Step 3's unmerge-detection heuristic before filing the action-request – the refusal table below uses the detection result to pick the right `action_type`. This is the only case where Step 3 runs even though we won't proceed to Step 4+.

**Allow only if ALL three are true** (read directly from the `profile_status` response):
- `profile.isClaimed == true`
- Exactly ONE entry in `profile.workspaces[]` has `isClaimed == true`
- That workspace's `email` matches `intercom_email` (case-insensitive)

If the ownership signal looks ambiguous, call `remove_credits` with `apply: false` anyway – the wrapper script will return a structured refusal envelope (e.g. `owner_mismatch`, `profile_unclaimed`) that you can route deterministically using the refusal table at the bottom of this skill.

**Refuse – file via `action-request` instead – if:**

| Case | What to tell the customer |
|------|---------------------------|
| Profile is unclaimed | "I can't make changes to an unclaimed profile from here – I've flagged this for our team to review." Then file `action-request` tier 2. Pick the action_type based on Step 3's heuristic: if the unmerge-detection fires, use `action_type: unmerge-request` (so Aaron gets the merge audit upfront); otherwise `action_type: credit-correction`. The two action_types lead to different ops playbooks, so picking the right one saves a triage round-trip. |
| Profile has multiple claimed workspaces | "This profile has multiple owners on it, so I'd like to have our team sort it out. I've flagged it for review." Then file `action-request` tier 2 (same routing rule as above – `unmerge-request` if detection fires, else `credit-correction`). |
| Email mismatch | "I'm not seeing this profile under your account. Could you double-check the URL?" Don't escalate by default; ask the customer to confirm. If they insist it's theirs, file tier 2 for ops to investigate. |

### Step 3 – Unmerge-mistake detection (capability B pre-step)

Before resolving titles, check whether what the customer is asking for is actually an unmerge.

For each track on the profile, look at TWO things:
- `artists[].name` – who's on the track
- `credits[]` – the profile owner's role(s) on the track (e.g., `["Producer"]`, `["Featured Artist"]`, `["Composer", "Lyricist"]`)

To gather the per-track signal, call `credits_search` paginated with `limit=100` and step `offset` until you've seen the whole profile (cap at ~5 pages = 500 credits). If the profile is larger than 500 credits, skip the per-track analysis and treat ANY listed-track-clustering signal you DO see as cause to file `unmerge-request` with `details.profile_size_too_large: true`; ops will fetch the rest.

**A track counts as "legitimately the profile owner's" if EITHER:**
- The profile name OR any entry in `profile.knownAsNames` (from `profile_status` output) is in the track's `artists[]` (case-insensitive), OR
- The profile owner's `credits[]` on that track includes any production-side role from the canonical list defined in `action-request/SKILL.md` under "Unmerge Request" (Producer, Co-Producer, Songwriter, Composer, Lyricist, Mixing, Mixing Engineer, Mastering, Mastering Engineer, Engineer, Recording Engineer, Arranger). **Producers and writers legitimately appear on tracks where they are NOT the primary artist** – this is the common case for beatmakers, songwriters, and engineers.

**Flag as unmerge case** ONLY when ALL of these hold:
- 10+ of the listed tracks are NOT legitimately the profile owner's by the rule above, AND
- The non-legit tracks share the SAME primary artist (a single foreign artist's catalog got pulled in), AND
- That foreign artist name doesn't appear in `profile.name` or `profile.knownAsNames`, AND
- The profile owner has no production-side role on those tracks (i.e. the per-track credits check failed too).

This is the pattern from Serhii's observation: the customer is describing track-removal, but the real problem is that another artist's catalog got merged into theirs.

**Producer-profile guardrail** (lesson from ticket 869ck6tv6, Alexxx): if the profile owner holds production-side roles on most credits – e.g., they're a producer or songwriter – then their profile legitimately shows many tracks by OTHER primary artists. The unmerge heuristic must NOT fire on this shape; that would be a false positive.

When this is the case AND the customer's request is vague (no specific tracks listed), gently push back instead of acting:

> "Looking at your profile, I see you're credited as a Producer on most of the tracks here – those are usually the records where you made the beat. Could you tell me which specific track(s) you want removed? It'd help me make sure I'm getting the right ones off."

Then wait for the customer to specify. Do NOT bulk-remove based on "tracks where the customer isn't the primary artist."

**If flagged, do NOT proceed with removal.** Instead:

1. Tell the customer:

   > "Looking at this, it seems like the issue might be that another artist's tracks got mixed into your profile, not just a few mis-attributed credits. Removing them one by one wouldn't fix the underlying merge. I've flagged this for our team to review – they'll look at the merge history and either unmerge or do a deeper fix. You'll hear back within 5 business days."

2. File via `action-request` with:
   - `action_type: unmerge-request` (tier-2 type – see `action-request/SKILL.md`)
   - `details.suspect_artist_names`: the artist name(s) flagged
   - `details.suspect_track_count`: how many of the listed tracks share that artist
   - `details.total_listed_count`: total tracks the customer asked about
   - `details.profile_name`: profile's display name from `profile.name`
   - `details.profile_known_as`: `profile.knownAsNames[]`
   - `details.customer_verbatim_request`: the customer's own words, unmodified
   - `details.suggested_action`: "investigate_as_unmerge"
   - `details.profile_size_too_large`: `true` only if you bailed on the per-track analysis because the profile had more than 500 credits (see Step-3 guidance above); omit otherwise.

   Note: `details.raw_profile_sources` (upstream sources) is NOT exposed by `profile_status`. Ops can fetch it directly via the admin API when investigating.

3. Done. Do not call the removal wrapper.

**Mixed cases**: if SOME of the listed tracks look like an unmerge case but others are unambiguously the profile owner's (e.g., 10 tracks by a wrong-artist, plus 2 tracks the owner themselves wants gone), still escalate via `unmerge-request` – include ALL the customer's listed tracks in `customer_verbatim_request`. Ops can split the fix manually if needed. Caroline does NOT execute a partial removal alongside the escalation; that would be processing what the customer asked for while the underlying problem is still un-decided.

### Step 4 – Resolve titles to track IDs (capability A only)

If capability A:

1. List profile credits (already in `credits_search` / `profile_status` output, or re-fetch via the wrapper's dry-run).
2. Normalize each customer "Artist - Title" line: lowercase, strip `(feat. X)` / `(ft. X)`.
3. Match against profile credits where normalized titles match AND any `artists[].name` (normalized) matches the customer's artist.

The wrapper script does this matching itself in step 6 – Caroline doesn't need to compute the resolution by hand. She just needs to NOT proceed if the inputs are obviously wrong (no profile, no tracks).

### Step 5 – Preview and customer confirmation

**This step is mandatory.** Caroline calls `remove_credits` in dry-run mode (`apply: false`) to get the resolved set, shows it to the customer, and waits for explicit confirmation before applying.

**If the dry-run resolves ZERO tracks** (all rows came back `not_found` or `ambiguous`), do NOT proceed to apply. Instead, tell the customer:

> "I couldn't match any of the tracks you listed against your profile – they might be spelled slightly differently, or they may have already been removed. Could you double-check the titles, or paste a Spotify/Apple Music link for one or two of them?"

Wait for them to clarify. If after one round of clarification the resolution is still zero, file `action-request` (tier 1, `action_type: credit-correction`) with the customer's verbatim list – ops can dig into the catalog manually.

Dry-run call:

```
remove_credits({
  profileId: "<uuid>",
  requesterEmail: "<intercom_email>",
  tracks: ["Don Pero - Big Don Dada", "Don Pero - Baby Mama", ...],
  apply: false,
  intercomConvId: "<conv_id>"
})
```

Read the wrapper's JSON output and present the summary to the customer:

> "I can remove the following from your profile:
>   • Don Pero - Big Don Dada
>   • Don Pero - Baby Mama
>   • Baby Gang - Bentley (feat. Simba La Rue, J Lord)
>
> A couple I couldn't match – could you double-check these?
>   • Don Pero - Notatrack Xyz (didn't find this one)
>
> Want me to go ahead and remove the three I can find?"

Wait for an explicit "yes" / "remove them" / "go ahead." Do not proceed on ambiguous replies ("maybe", "I think so").

### Step 6 – Apply removal (capability A only, after confirmation)

Call `remove_credits` again with the same tracks list but `apply: true`:

```
remove_credits({
  profileId: "<uuid>",
  requesterEmail: "<intercom_email>",
  tracks: ["Don Pero - Big Don Dada", "Don Pero - Baby Mama", ...],
  apply: true,
  intercomConvId: "<conv_id>"
})
```

The parameter schema accepts exactly these five fields. Do not invent additional fields – even when the runtime doesn't reject unknowns at the schema level, the wrapper script ignores them and the agent has no upside to passing them.

**Pass `intercomConvId` whenever you have it.** Required for `apply: true`. Strongly recommended on dry-run too – the wrapper uses it to verify your `requesterEmail` matches the Intercom contact's actual email-of-record whenever a conv-id is present, closing a message-text injection vector. Missing conv-id on dry-run means that verification is skipped on that call. (The dry-run audit row records the conv-id for forensics, but the apply-gate match key is `(profile_id, requester_email, track_id)` – not the conv-id.)

**Mechanical apply gate**: when `apply: true`, the wrapper refuses unless every track being applied has a matching `would_remove` audit row from the last 15 min. If you ran the dry-run, got customer confirmation, and call apply within 15 minutes, this is invisible. If the confirmation took longer or you tried to apply tracks that weren't in the dry-run preview, the wrapper refuses with `dry_run_required` – re-run the dry-run and try again.

### Step 7 – Report back

Read the wrapper's JSON output and compose the customer-facing reply.

Key fields in the wrapper response:
- `ok` (bool) – true if the script ran cleanly (the customer-facing outcome may still include some rows that couldn't be processed)
- `mode` – "apply" or "dry-run"
- `summary.removed` – how many tracks were actually deleted
- `summary.already_removed` – tracks the API returned 404 for (idempotent – likely fine)
- `summary.not_found` – couldn't match the input to a credit
- `summary.ambiguous` – input matched more than one credit on the profile
- `summary.errors` – HTTP errors on individual deletions (not refusal of the whole batch)
- `results[]` – per-row breakdown

Compose the reply:

```
"Done – removed N of M:
  • <list of removed titles>

[If not_found > 0:]
A few I couldn't match on the profile:
  • <list of inputs that came back not_found>
[Could you double-check those? Either the title is slightly different or they were already removed.]

[If ambiguous > 0:]
A couple were ambiguous (more than one track with that title):
  • <list>
Could you share Spotify links for those? That'll help me pick the right one."
```

If `summary.errors > 0`, tell the customer some failed and that you've flagged them for the team. File an `action-request` (tier 2) with the failing rows in `details.failed_removals[]`.

## Refusal handling (full table)

Every refusal returned by `remove_credits` is a JSON object `{ok: false, error: <key>, detail?: <string>}`. Customer-facing replies:

| `error` key | Caroline's reply | Follow-up action |
|------------|------------------|------------------|
| `rate_limited` | "Looks like we've made a few changes already – let's give it a moment and try again in a bit." | Wait; the cap resets after 60 min |
| `wrapper_empty_output` / `wrapper_invalid_output` / `wrapper_exec_failed` | "Something's off on our end – I've let the team know and someone will look at it." | File `action-request` tier 2 with the error key + detail |
| `missing_arg` / `invalid_*` / `tracks_file_missing` / `unknown_arg` | Internal bug – don't tell the customer about it; retry with corrected args | Log to session for review |
| `empty_tracks_file` | "Could you list the tracks you want removed? One per line works best." | Wait for customer |
| `cap_exceeded_per_request` | "That's more than I can do in a single round – let me handle the first 50 now and we can do the rest after. Want me to start with the first 50?" | Split into batches with confirmation each time |
| `apply_batch_too_large` | "Let me apply these in a couple of smaller batches so nothing times out – I'll do the first 15 now, then carry on with the rest. Sound good?" | The dry-run already previewed them all; re-call `remove_credits` with `apply: true` on ≤ `max_apply_tracks` tracks at a time, confirming each batch. Not a customer error – purely an internal batching limit. |
| `cap_exceeded_per_day` | "I've helped you remove quite a few today already – to be safe, let me flag the rest for our team to handle." | File `action-request` tier 1 with the leftover tracks |
| `profile_lookup_failed` | "Hmm, having trouble loading that profile – could you share the URL again so I can double-check it?" | If repeats, file `action-request` tier 2 |
| `profile_unclaimed` | "I can't make changes to an unclaimed profile from here – I've flagged this for our team." | File `action-request` tier 2, action_type `credit-correction` |
| `no_claimed_workspace` | same as `profile_unclaimed` (rare edge case) | same |
| `profile_multi_claimed` | "This profile has multiple owners – I'd like to have our team sort it out. Flagged for review." | File `action-request` tier 2 |
| `owner_mismatch` | "I'm not seeing this profile under your account. Could you double-check the URL?" | If customer insists, file tier 2 |
| `intercom_conv_id_required` | Don't surface to customer – this is an internal contract bug. Retry the same call WITH `intercomConvId` from the conversation context | Log; if it repeats across retries, file tier 2 |
| `intercom_email_mismatch` | "For destructive changes I have to make sure I'm talking with the right person – could you tell me a bit more about who you are and what you're trying to do? I've also flagged this for our team to double-check." | File `action-request` tier 2, `escalation_reason: "intercom_email_mismatch"`. Possible impersonation – treat as a signal worth ops eyes. |
| `dry_run_required` | "Let me run that one more time to confirm what we're removing." Then call `remove_credits` with `apply: false` again, show the preview, get confirmation, then re-apply. | If happens twice in the same conversation, file tier 2 |
| `missing_admin_api_script` / `credits_list_failed` / `credits_list_too_large` | "Something's off on our end – I've let the team know and someone will look at it." | File `action-request` tier 2 with the error key |
| `invalid_intercom_conv_id` | Don't surface to customer – internal contract bug. Retry the same call without conv_id (dry-run only) OR with a valid alphanumeric conv-id | Log; if it repeats, file tier 2 |
| `ops_dry_run_set` / `audit_unwritable` | "Something's off on our end – I've let the team know and someone will look at it." | File `action-request` tier 2 with the error key. Both indicate a host-side ops issue (env misconfiguration or audit-log permissions); flag for ops attention. |
| `refused_production_role_on_track` (per-row in `results[]`, not a top-level `error`) | "Looking at this, you're credited as a {role} on this track, which is usually a deliberate listing rather than a mis-attribution. Could you double-check whether you really want that removed? If so, I'll pass it to our team to handle." | Wait for explicit re-confirmation; if customer insists, file `action-request` tier 2 (`action_type: credit-correction`) listing the role-affected tracks. |
| `upstream_dry_run_short_circuit` (per-row in `results[]`) | "Something's off on our end – I've let the team know and someone will look at it." | File `action-request` tier 2. This indicates `OPS_DRY_RUN=1` somewhere in the prod path – high-priority ops issue. |

Never use the words "ticket," "ClickUp," "wrapper," "script," "API," "DELETE," or `support@muso.ai` in customer-facing replies. Stay conversational.

## Operational notes

- Per-request cap: 50 tracks. Per-customer-per-day cap: 100 tracks. Both enforced inside the wrapper.
- Audit log lives at `/var/log/openclaw/customer-credit-removal.jsonl` – one line per attempted removal (resolved or refused). Operations can grep this if a customer disputes.
- Idempotency: re-running on the same input is safe – the second run reports `already_removed` for tracks the first run removed (the API returns 404 for already-removed credits).
- Field paths (`isClaimed`, `workspaces[].email`, etc.) are recon-confirmed against the live admin API as of 2026-05-25. See `reference_muso_admin_api_profile_fields.md` (operator memory) if they ever drift.
