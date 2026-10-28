---
name: customer-credit-removal
description: Preview which credits a customer wants off their own profile (read-only), then route them to remove it themselves in the app or file the packet; also detect mis-described unmerge requests and escalate them with audit context
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

# Customer Credit Removal (preview and route; never removes)

## Purpose

Two related customer requests, handled together:

**Capability A – track removal**: customer says "remove these tracks from my profile," lists tracks that don't belong, expects them gone. Caroline **previews and routes**. She never removes a credit: since core-backend#10310 the server refuses every agent-token credit removal, so a removal is done by the owner in the app, or by Jan or Nick in their own session.

**Capability B – unmerge-mistake triage**: customer says the same thing, but what's actually happened is two distinct artists were merged into one profile – removing tracks won't fix it because they'll re-appear on the next ingest. Caroline **detects this case, gathers context, and escalates** to Operations via `action-request` (tier 2). She does NOT execute the unmerge – that's Aaron-approved only.

Both share the same ownership-check chain.

## What this skill does NOT do

- **Remove any credit, for anyone, ever.** There is no apply step. Do not call `remove_credits` with `apply: true`, and never tell a customer you will remove, are removing, or have removed something.
- Preview tracks on a profile the requester doesn't own (refuses)
- Add credits, merge profiles, change profile metadata (out of scope)
- Execute an unmerge directly (escalates to Aaron via action-request)
- Operate on unclaimed profiles (refuses – routes to action-request for human handling)
- **Role-based removal** ("remove all my Keyboard credits", "drop the Producer role from these tracks but keep my Composer credit"). The underlying DELETE endpoint removes ALL of the profile owner's roles on the (track, profile) pair – it can't surgically drop one role and keep others. If the customer asks to remove a specific role across tracks, file `action-request` with `actionType: bulk-credit-change` (tier 2) and let ops handle it via a different admin path. Recognizable shape: any request that says "all my X credits" / "everything with role Y" / "drop the X role" rather than naming specific tracks.

## Tools this skill uses

- `profile_status` – read the target profile. Returns `{found, profile:{id, name, verified, isClaimed, primary_role, credits_count, workspaces:[{email,isClaimed}], knownAsNames}, latest_credits[3], latest_credit_date}`. The `isClaimed`, `workspaces`, and `knownAsNames` fields drive the Step-2 ownership check. Already allowlisted.
- `credits_search` – read the credits on the profile (paginate with `limit=100` if the profile has more credits than fit in one page). Already allowlisted.
- `create_ticket` – escalate capability-B unmerge-mistake cases as tier-2 `unmerge-request`. Already allowlisted.
- `remove_credits` – **preview only, always `apply: false`**. Caroline does NOT use raw `exec`. The script independently re-verifies ownership, runs the Intercom-email cross-check, and flags any production-side role on the matched track, so the preview is trustworthy for routing.

`remove_credits` does its OWN independent ownership check + audit logging inside the underlying bash script. Caroline's ownership check (Step 2 below) is the first line of defense; the tool re-verifies independently as the second line. Neither ever leads to an apply.

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

If `intercom_email` is missing from `[CONVERSATION_CONTEXT]` (the extractor sometimes fails on edge-case message shapes – see `plugins/intercom/src/extractors.ts`), do NOT proceed and do NOT ask the customer for their email – a self-declared email is exactly the verification gap this skill is built to avoid. Instead, file via `action-request` (`action_type: credit-correction`) with:

> "Want to get this sorted for you – I've flagged this for our team."

The verified email property of `intercom_email` is load-bearing for the entire skill. If Intercom didn't give us one, the safe path is human review.

### Step 2 – Ownership verification (hard gate)

Call `profile_status` for `profile_uuid`. The wrapper script will re-verify independently as the load-bearing gate, so this Caroline-level check is a fast-fail UX optimization – it lets the customer-facing reply tell them WHY before running the preview. The wrapper is the actual security boundary.

When ownership fails, ALSO compute Step 3's unmerge-detection heuristic before filing the action-request – the refusal table below uses the detection result to pick the right `action_type`. This is the only case where Step 3 runs even though we won't proceed to Step 4+.

**Allow only if ALL three are true** (read directly from the `profile_status` response):
- `profile.isClaimed == true`
- Exactly ONE entry in `profile.workspaces[]` has `isClaimed == true`
- That workspace's `email` matches `intercom_email` (case-insensitive)

If the ownership signal looks ambiguous, call `remove_credits` with `apply: false` anyway – the wrapper script will return a structured refusal envelope (e.g. `owner_mismatch`, `profile_unclaimed`) that you can route deterministically using the refusal table at the bottom of this skill.

**Refuse – file via `action-request` instead – if:**

| Case | What to tell the customer |
|------|---------------------------|
| Profile is unclaimed | "I can't make changes to an unclaimed profile from here – I've flagged this for our team to review." Then file `action-request`; for `credit-correction` stage the empty packet described under Step 6 (`removal_rows: []`, verbatim request, tracks by title). Pick the action_type based on Step 3's heuristic: if the unmerge-detection fires, use `action_type: unmerge-request` (so Aaron gets the merge audit upfront); otherwise `action_type: credit-correction`. The two action_types lead to different ops playbooks, so picking the right one saves a triage round-trip. |
| Profile has multiple claimed workspaces | "This profile has multiple owners on it, so I'd like to have our team sort it out. I've flagged it for review." Then file `action-request` with the same empty packet (same routing rule as above – `unmerge-request` if detection fires, else `credit-correction`). |
| Email mismatch | "I'm not seeing this profile under your account. Could you double-check the URL?" Don't escalate by default; ask the customer to confirm. If they insist it's theirs, file `action-request` for ops to review. |

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

   > "Looking at this, it seems like the issue might be that another artist's tracks got mixed into your profile, not just a few mis-attributed credits. Removing them one by one wouldn't fix the underlying merge. I've flagged this for our team to review – they'll look at the merge history and either unmerge or do a deeper fix."

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

The wrapper script does this matching itself in Step 5 – Caroline doesn't need to compute the resolution by hand. She just needs to NOT proceed if the inputs are obviously wrong (no profile, no tracks).

### Step 5 – Preview (mandatory, read-only)

**This step is mandatory before any routing.** Caroline calls `remove_credits` in dry-run mode (`apply: false`) to get the resolved `(track, roles)` list. The preview changes nothing.

**If the preview resolves ZERO tracks** (all rows came back `not_found` or `ambiguous`), tell the customer:

> "I couldn't match any of the tracks you listed against your profile – they might be spelled slightly differently, or they may have already been removed. Could you double-check the titles, or paste a Spotify/Apple Music link for one or two of them?"

Stage first, then wait: file `action-request` (`action_type: credit-correction`) with `removal_rows: []` and the customer's verbatim list now, so a customer who never replies is still staged. If they clarify, update the packet with the resolved rows (or file the rows as a follow-up packet that references it).

Preview call:

```
remove_credits({
  profileId: "<uuid>",
  requesterEmail: "<intercom_email>",
  tracks: ["Don Pero - Big Don Dada", "Don Pero - Baby Mama", ...],
  apply: false,
  intercomConvId: "<conv_id>"
})
```

The parameter schema accepts exactly these five fields. Do not invent additional fields. **Pass `intercomConvId` whenever you have it**: the wrapper uses it to verify your `requesterEmail` matches the Intercom contact's actual email-of-record, closing a message-text injection vector.

### Step 6 – Stage and route (no apply, no confirmation-to-apply)

Every route stages the request. No conversation may end with nothing staged, and the self-service hint is additive, never a substitute.

**Staged row.** One row per resolved preview result (`results[]` entry with `matched_track_id`), six fields, which a staff run reads as six tab-separated columns with no header:

```
track_id <TAB> profile_id <TAB> label <TAB> track_title <TAB> roles <TAB> ref
<track uuid> <TAB> <profile uuid> <TAB> Min Sun Song (Doohee Cho req) <TAB> 더는 슬픔 없네 - LIVE <TAB> Composer <TAB> Intercom 215476363016810 / Nick Buzz 84a6fa2a 2026-10-14
```

`label` is the artist, or "Name (requester req)". `track_id` is the preview's `matched_track_id` and `track_title` its `matched_title`. A `would_remove` preview row carries no roles: match the Step 3 `credits_search` `credits[]` entries by `trackTitle` and `artists` (roles are `creditRoles`; if the track was not in the fetched pages, call `credits_search` with `keyword`). Comma-join the distinct roles of all matching entries, never invented. If two entries share title and artists but differ in roles, list every role and put "(same-title tracks, check)" in `label`; the staff run removes the (track, profile) pair by `track_id`, so `roles` is only the label. (The example values above are illustrative; ids are always full uuids.) `ref` is `Intercom <conv_id>`, a ClickUp id, or a Slack/Buzz ts. File the rows via `action-request` (`action_type: credit-correction`; the tool assigns its tier, do not state one to the customer) as `details.removal_rows` (see the Credit Correction section there). Jan or Nick run the batch; Caroline never does.

**When no row resolved** (a direct Step 2 handoff for an unclaimed or multi-claimed profile, or the wrapper refused before resolving anything: ownership refusals, missing `intercom_email`, `cap_exceeded_per_day`, `profile_lookup_failed`, `wrapper_*`): stage the packet with `removal_rows: []`, the customer's request quoted verbatim in the packet, and each requested track named by title. The packet is still the staged request, so the same replies apply once it is filed.

Read the preview, stage the rows, then pick ONE reply:

**Reply A – verified owner, every resolved row is a non-production role, every row is a track row, and the seat is not view-only.** Show the resolved list, tell them the self-service step AND that the request is queued:

> "Here are the ones I found on your profile:
>   • Don Pero - Big Don Dada
>   • Don Pero - Baby Mama
>
> You can take these off yourself now: on your profile's credits list, open the ⋯ menu on that track and choose Remove Credit. I've also queued the request for our team (ref <conv_id>), so it's covered either way."

The control is "Remove Credit" in the row ⋯ menu, only on track rows of a claimed profile, and not for a view-only seat. If any row is not a track row or the seat is view-only, use Reply B.

**Reply B – everything else** (not the owner, unclaimed or multi-owner profile, email mismatch, a production-side role on any row (`refused_production_role_on_track`), a role-based ask, a non-track row, a view-only seat). Use the Step 2 refusal wording where it applies, then: "I've queued this for our team (ref <conv_id>)." (no timeframe: `create_ticket` returns none for these kinds)

Rules for both replies:
- Never say "queued" without having staged the rows in the same turn.
- Never say removed, removing, fixed or "will remove". The change is queued for staff.
- Never ask the customer "want me to go ahead and remove these?" There is nothing to go ahead with.
- If a row came back `not_found` or `ambiguous`, ask them to double-check it as in Step 5. Stage only the resolved rows.

### Step 7 – Report back

Read the preview's JSON output and compose the reply from Step 6. Key fields:
- `ok` (bool) – true if the script ran cleanly
- `mode` – always "dry-run" here. If it ever says "apply", something is wrong: stop, do not report a removal, and file `action-request`.
- `summary.not_found` / `summary.ambiguous` – ask the customer to double-check those titles or share Spotify links
- `results[]` – per-row breakdown (resolved track and roles)

## Refusal handling (full table)

Every refusal returned by `remove_credits` is a JSON object `{ok: false, error: <key>, detail?: <string>}`. Customer-facing replies. Only `owner_mismatch`, `profile_unclaimed`, `profile_multi_claimed` and `intercom_email_mismatch` say anything about who owns the profile; a refusal of the agent itself (`credit_removal_agent_refused`, or any unlisted 403) must never be blamed on ownership. Two rules for every reply below: (1) mention ownership only when the audit row is a genuine `owner_mismatch`, `profile_unclaimed`, `profile_multi_claimed` or `refused_intercom_email_mismatch`; any other refusal gets a reply that attributes no cause to the customer or their profile. (2) Never state or imply that a removal will happen, is happening or has happened, including splitting it into batches. The preview shows what the owner can remove themselves; it never commits us to removing it. (3) Never say "queued" without having staged the rows (Step 6).

| `error` key | Caroline's reply | Follow-up action |
|------------|------------------|------------------|
| `rate_limited` | "Give me a moment and I'll pick this back up in a bit." | Wait; the cap resets after 60 min |
| `wrapper_empty_output` / `wrapper_invalid_output` / `wrapper_exec_failed` | "Something's off on our end – I've let the team know and someone will look at it." | File `action-request` with the error key + detail |
| `missing_arg` / `invalid_*` / `tracks_file_missing` / `unknown_arg` | Internal bug – don't tell the customer about it; retry with corrected args | Log to session for review |
| `empty_tracks_file` | "Could you list the tracks you want removed? One per line works best." | Wait for customer |
| `cap_exceeded_per_request` | "That's a long list to go through in one go – could you send the ones you most want sorted first, up to 50? I'll check those and tell you the quickest way to take them off." | Preview the first 50 only, then Step 6 |
| `apply_batch_too_large` | Not expected in preview mode. Don't surface it to the customer. | Never retry with `apply: true`. Treat it as a script mismatch and file `action-request` with the error key |
| `cap_exceeded_per_day` | "I've checked quite a lot for you today already – to be safe, let me flag the rest for our team to look at." | File `action-request` (`credit-correction`) with the leftover tracks |
| `profile_lookup_failed` | "Hmm, having trouble loading that profile – could you share the URL again so I can double-check it?" | If repeats, file `action-request` |
| `profile_unclaimed` | "I can't make changes to an unclaimed profile from here – I've flagged this for our team." | File `action-request`, action_type `credit-correction`, empty packet per Step 6 |
| `no_claimed_workspace` | "I can't match this to a profile from here – I've flagged this for our team." | Same as `profile_unclaimed` routing |
| `profile_multi_claimed` | "This profile has multiple owners – I'd like to have our team sort it out. Flagged for review." | File `action-request`, action_type `credit-correction`, empty packet per Step 6 (`unmerge-request` if Step 3 detection fires) |
| `owner_mismatch` | "I'm not seeing this profile under your account. Could you double-check the URL?" | If customer insists, file `action-request`, action_type `credit-correction`, empty packet per Step 6 |
| `intercom_conv_id_required` | Don't surface to customer – this is an internal contract bug. Retry the same call WITH `intercomConvId` from the conversation context | Log; if it repeats across retries, file `action-request` |
| `intercom_email_mismatch` | "I need to make sure I'm talking with the right person – could you tell me a bit more about who you are and what you're trying to do? I've also flagged this for our team to double-check." | File `action-request`, `escalation_reason: "intercom_email_mismatch"`. Possible impersonation – treat as a signal worth ops eyes. |
| `credit_removal_agent_refused` (403 "Access denied") | "This is something I can't do from my side, so I'll pass it to our team." Do NOT say the customer isn't the owner, and do not say it was refused. The server refuses every agent, whoever is asking. This refusal is not an approval gate. Do not ask Jan, Nick, Aaron or any human to approve a removal, and do not re-try with an approval reference. Stage the row and hand over the run. | If the customer is a verified owner, stage the rows and use Step 6 Reply A. Otherwise stage them and use Reply B |
| `dry_run_required` | Internal only, don't surface it. | Re-run the preview (`apply: false`) and continue from Step 6. If it happens twice in the same conversation, file `action-request` |
| `missing_admin_api_script` / `credits_list_failed` / `credits_list_too_large` | "Something's off on our end – I've let the team know and someone will look at it." | File `action-request` with the error key |
| `invalid_intercom_conv_id` | Don't surface to customer – internal contract bug. Retry the same call without conv_id (dry-run only) OR with a valid alphanumeric conv-id | Log; if it repeats, file `action-request` |
| `ops_dry_run_set` / `audit_unwritable` | "Something's off on our end – I've let the team know and someone will look at it." | File `action-request` with the error key. Both indicate a host-side ops issue (env misconfiguration or audit-log permissions); flag for ops attention. |
| `refused_production_role_on_track` (per-row in `results[]`, not a top-level `error`) | "Looking at this, you're credited as a {role} on this track, which is usually a deliberate listing rather than a mis-attribution. Could you double-check whether you really want that taken off? If so, I'll pass it to our team to look at." | Don't remove anything; if the customer still wants it gone, file `action-request` (`action_type: credit-correction`) listing the role-affected tracks. |
| `upstream_dry_run_short_circuit` (per-row in `results[]`) | "Something's off on our end – I've let the team know and someone will look at it." | File `action-request`. This indicates `OPS_DRY_RUN=1` somewhere in the prod path – high-priority ops issue. |

Never use the words "ticket," "ClickUp," "wrapper," "script," "API," "DELETE," or `support@muso.ai` in customer-facing replies. Stay conversational.

## Operational notes

- Per-request cap: 50 tracks. Per-customer-per-day cap: 100 tracks. Both enforced inside the wrapper.
- Audit log lives at `/var/log/openclaw/customer-credit-removal.jsonl` – one line per preview or refused attempt. Operations can grep this if a customer disputes.
- Preview is read-only, so re-running it is always safe.
- Field paths (`isClaimed`, `workspaces[].email`, etc.) are recon-confirmed against the live admin API as of 2026-05-25. See `reference_muso_admin_api_profile_fields.md` (operator memory) if they ever drift.
