---
name: muso-audit-profile-credits
description: |
  Per-track audit of every existing approved credit on a Muso profile. Diffs
  the profile's credit list against the industry-sourced catalog in Athena,
  bucketing each track as 🟢 industry-confirmed / 🟡 user-added externally
  verifiable / 🟠 user-added unverified / 🔴 missing from catalog. Produces
  a Slack-formatted per-track breakdown for ops review and removal decisions.

  Use when: auditing all credits of a profile, bulk-verifying existing credits,
  "verify all the tracks of this profile", deciding which credits to prune on
  a suspect profile. Distinct from `muso-verify-profile` (aggregate legitimacy
  score) — this skill produces per-track verdicts.

  Triggers: "audit all credits", "verify all credits", "audit the tracks of
  this profile", "which credits are legit", "bulk credit audit",
  "per-track audit"
compatibility: |
  Requires: muso-ops-admin (admin API), muso-query-writer (Athena), browser
  tool for external cross-reference. Slack formatter for output.
depends-on:
  - muso-ops-admin
  - muso-ops-audit
  - muso-query-writer
  - muso-slack-formatter
metadata:
  version: "1.0"
  source-repo: "Muso-AI/hydra"
---

# Muso Ops — Audit Profile Credits

Produce a per-track verdict for every approved credit on a profile. The goal
is NOT an aggregate legitimacy score (see `muso-verify-profile` for that) —
the goal is a table the ops team can act on: *"these N credits look good, these
M need review, remove/keep each one individually"*.

## When to invoke

- Jan/Aaron asks "verify all the credits on profile X"
- A profile flagged by the fraud scan needs a per-credit follow-up
- Cleanup pass on a profile with mixed self-claimed + industry credits
- Delegated from `muso-ops-credit-verification` Step 2a when the input is a
  profile UUID and the human intent is per-track audit (not pending-request
  verification)

## Access

All ops team members may invoke (read-only analysis + optional per-credit
removal). Credit DELETE calls require Tier 1-3 authorization and go through
the standard `muso-ops-admin` audit trail. This skill does not auto-remove
credits — it produces a recommendation list.

## Inputs

- `profile_id` (UUID). Required.
- `requester` email or Slack ID (passed to `muso-admin-api.sh --requester`
  so the audit trail records who triggered the run).

## Investigation Steps

### Step 1: Profile baseline (Admin API)

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  --requester "$REQUESTER" \
  call GET "/admin/profile/$PROFILE_ID"
```

Extract: `name`, `creditCount`, `isClaimed`, `workspaces[].email`,
`auditStats.criticalIssues.tracksCount`, `auditStats.partialIssues.tracksCount`.

If the profile is not claimed (`isClaimed: false` and no workspaces), the
entire credit set is industry-sourced by definition — aggregate verdict is
🟢 by construction and there is nothing to audit per-track. Post a brief note
and stop. Do NOT continue to Step 2.

### Step 2: Full credit list (Admin API, paginated)

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  --requester "$REQUESTER" \
  call GET "/admin/profile/$PROFILE_ID/credits?limit=500&offset=0"
```

Paginate with `offset` in 500-item increments until the response returns fewer
than `limit` items. **Hard scope cap: 2000 credits.** If the profile has more
than 2000 credits, audit the 2000 most-popular tracks and declare the cap
explicitly in the Slack post (*"capped at 2000 most-popular credits; N
remaining unaudited"*). Do NOT silently truncate — per the HARD RULE on
search-scope claims in `muso-ops-credit-verification`, every scope boundary
must be stated in the final output.

Build `API_CREDITS`: a dict keyed by `trackId`, with `{title, credits[],
popularity, status, addedAt}` per track.

### Step 3: Industry-confirmed set (Athena)

Pull every track in the industry-sourced catalog that references this profile
in its authoritative `profiles[]` array:

```sql
SELECT
  t._id                        AS track_id,
  t.title                      AS title,
  t.popularity                 AS popularity,
  t.default_release_label      AS label,
  t.release_timestamp          AS released,
  TRANSFORM(t.profiles, p -> p.role) AS roles_on_track
FROM hive."platform-industry-bi-prod".matvw_catalog_track t
WHERE contains(TRANSFORM(t.profiles, p -> p.profile_id), '<PROFILE_ID>')
  AND t.is_deleted = false
ORDER BY t.popularity DESC
LIMIT 5000
```

Build `INDUSTRY_CONFIRMED`: set of `track_id`s returned by this query plus
per-track metadata.

`matvw_catalog_track.profiles` is the authoritative mapping from industry
feeds (label metadata, distributor data, MLC, publishing databases) — NOT
user-claimed edits. A track appearing here means a trusted upstream source
says this profile is credited.

### Step 4: Bucket each credit

For every `(track_id, api_credit)` in `API_CREDITS`:

| Condition | Bucket | Emoji | Meaning |
|---|---|---|---|
| `track_id in INDUSTRY_CONFIRMED` AND `api_credit.credits ⊆ industry.roles_on_track` | `industry_confirmed` | 🟢 | Credits match industry data exactly |
| `track_id in INDUSTRY_CONFIRMED` AND `api_credit.credits ⊄ industry.roles_on_track` | `role_expanded` | 🟢⚠️ | Track is industry-confirmed but ops/user added extra roles — note, usually fine |
| `track_id NOT in INDUSTRY_CONFIRMED` AND resolves on Spotify/TIDAL with name match | `user_added_verified` | 🟡 | User-added, externally corroborated |
| `track_id NOT in INDUSTRY_CONFIRMED` AND external check inconclusive | `user_added_unverified` | 🟠 | User-added, no external corroboration → needs review |
| `track_id NOT in INDUSTRY_CONFIRMED` AND track does not exist in Athena at all | `suspicious` | 🔴 | Ghost track → investigate |

Cap the external-check step at **20 tracks** to avoid excessive browser time.
Select the 20 by: all 🔴 first, then 🟠 highest-popularity-first. State the
cap in the Slack post if more 🟠 tracks exist uninvestigated.

### Step 5: External cross-reference (browser, sampled)

For each track in the external-check sample:

```
browser navigate -> https://open.spotify.com/track/<spotifyTrackId>
```

Extract the credits section and check whether the profile's `name` (or any
`knownAsNames`) appears. Similarly on `https://tidal.com/track/<tidalId>` if
the Muso record has a TIDAL mapping.

- Name appears → bucket stays 🟡 (`user_added_verified`)
- Name does not appear → bucket stays 🟠 (`user_added_unverified`)
- Track page 404s or the `spotifyTrackId` is missing → bump to 🔴
  (`suspicious`) and note *"track not resolvable externally"*

Tier 1 web_fetch blocks apply (enforced by
`muso-credit-verification-enforcer`) — use `browser`, not `web_fetch`, for
Spotify/TIDAL/AllMusic/Discogs/MusicBrainz.

### Step 6: Audit log (mandatory)

Write one entry to `api-logs/admin/YYYY-MM-DD.jsonl` before posting, per the
contract in `muso-ops-audit`:

```json
{
  "ts": "<ISO8601>",
  "skill": "muso-audit-profile-credits",
  "requester": "<email>",
  "profile_id": "<uuid>",
  "totals": {"credits_audited": N, "industry": X, "user_verified": Y, "user_unverified": Z, "suspicious": K},
  "scope": {"credits_cap": 2000, "external_cap": 20, "truncated": true|false}
}
```

### Step 7: Post to Slack

Reply in-thread on the originating mention (never top-level — see
`muso-ops-credit-verification` posting rules). Use Slack mrkdwn, no tables.

Required sections in this order:

1. **Header** with profile name, ID, and URL.
2. **Scope statement** — how many credits were audited, caps applied.
3. **Bucket summary** — counts + percentages.
4. **🟠 Review queue** — every user-added-unverified track: title, credits,
   popularity, spotify/tidal link. Ops decides keep/remove per-item.
5. **🔴 Suspicious** (if any) — every suspicious track: title, reason it
   failed (not in catalog / not resolvable). These are the priority items.
6. **Delta vs `muso-verify-profile`** — if a prior `muso-verify-profile` run
   exists for this profile in the same thread, note whether the per-track
   audit aligns with the aggregate verdict.

## Output Format (Slack)

```
🔍 *Profile Credit Audit: <NAME>*
Profile: <muso_profile_url>
Audit ID: <audit_log_entry_id>

*Scope*
• Audited <N> of <M> total credits (capped at 2000, <M-N> remaining)
• External checks: <K> of <U> 🟠/🔴 tracks (capped at 20)

*Summary*
• 🟢 Industry-confirmed: <N> (<%>)
• 🟢⚠️ Industry-confirmed with expanded roles: <N> (<%>)
• 🟡 User-added, externally verified: <N> (<%>)
• 🟠 User-added, unverified: <N> (<%>) ← needs review
• 🔴 Suspicious: <N> ← investigate first

*🔴 Suspicious (<N>)*
• "<title>" — credits: <Mixing, Engineer> — reason: not in industry catalog
  [<spotify link>] [<tidal link>]
...

*🟠 Review Queue (<N>)*
• "<title>" — credits: <Producer> — popularity: <P>
  Spotify: no credit match for "<NAME>". Tidal: not checked (cap).
  [<spotify link>]
...

*Recommendation:* <N> credits need ops review. <K> suspicious credits should
be investigated before user-added-unverified.
```

## Edge cases

- **Profile has 0 API credits but Athena has industry-confirmed tracks**:
  sync lag; post *"API returns 0 credits for profile; Athena shows X
  industry-sourced tracks — possible sync lag, investigate via backend
  team"* and stop.
- **Athena returns 0 but API returns N credits**: the profile has NO
  industry-sourced credits. Every credit is in the 🟡/🟠/🔴 pool. This is
  common for professionals whose industry records don't track them (live
  engineers, ghost producers) but also common for fraud. The external check
  in Step 5 becomes the only signal — sample aggressively (up to 20) and
  lean toward escalation rather than approval.
- **Profile has more than 2000 credits**: not attempted; post *"profile has
  <M> credits, exceeds 2000-cap, not audited — escalate to engineering for
  batched workflow"*. Do not silently truncate.
- **Athena query times out or errors**: post the error verbatim and stop.
  Do not approximate with API-only data — you'd lose the industry-confirmed
  signal, which is the whole point.
- **Admin API returns 5xx mid-pagination**: post what's known, explicit
  truncation statement (*"pagination interrupted at offset <N>, audit
  incomplete"*), do not claim full-scope.

## HARD RULE — search-scope honesty

Every Slack post MUST state:
1. Exactly how many credits were audited.
2. Whether the 2000 cap was hit.
3. Whether the external-check 20 cap was hit.

Never post *"audited all credits"* unless you audited all of them. This rule
inherits from `muso-ops-credit-verification` and is load-bearing.

## Cost Notes

- Admin API `/admin/profile/{id}/credits`: cheap (indexed lookup).
- Athena `matvw_catalog_track` with `contains(TRANSFORM(profiles))`: this
  table has ~190M rows; the TRANSFORM+contains filter cannot use partitions,
  so it's a full scan unless you add a partition filter. If cost becomes an
  issue, add `AND t.release_year >= 2010` (or equivalent) to limit scan.
  Typical cost for one profile audit: ~2-5 GB scanned (~$0.01-0.03).
- Browser checks: ~1-2s per track, 20 tracks → ~30-45s. Primary latency.

## Related skills

- `muso-verify-profile` — aggregate legitimacy score (IPI, claiming, external).
  Often run first; this skill drills down on the credit list that
  `muso-verify-profile` summarizes.
- `muso-ops-credit-verification` — reactive credit-request verification
  (new additions). Step 2a may delegate here when the human intent is per-
  track audit of existing credits.
- `muso-credit-investigator` — fraud-focused deep dive on a specific credit
  request or user; more investigation-shaped than this skill's per-track
  audit shape.
