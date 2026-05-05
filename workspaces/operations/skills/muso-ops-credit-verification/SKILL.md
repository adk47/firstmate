---
name: muso-ops-credit-verification
description: |
  Autonomous credit verification workflow. Two modes:
  1. Reactive: Triggered by any message in #credit-verification (C0APB2CMM7C).
     No @mention required. Parses flagged credit requests, investigates, and
     either auto-approves or moves to user_verification_needed. The bot does NOT
     auto-reject — rejection is a manual override from Jan/Aaron in escalation
     threads.
  2. Batch (cron): Proactively fetches up to OPS_BATCH_FETCH_SIZE unverified
     credits from the API every 4h (cron-jobs.json →
     credit-verification-batch-4h, `0 */4 * * *` UTC) and processes them,
     posting a summary to #credit-verification with a Jan-tagged thread reply.
     Target: 500 per run × 6 runs/day. Daily approval cap (500/UTC-day) still
     applies — excess LEGITIMATE verdicts log as skip_cap.

  Use when: any message arrives in #credit-verification channel, OR during
  heartbeat execution of the "Batch Credit Verification" task.

  Triggers: any message in #credit-verification (C0APB2CMM7C), heartbeat schedule
depends-on:
  - muso-ops-credits
  - muso-ops-fraud
  - muso-ops-admin
  - muso-ops-audit
  - muso-slack-formatter
compatibility: |
  Cross-repo dependency: core-backend PR #8465 must set rich text fallback
  in postCreditVerification() for the agent to parse the message content.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/hydra"
---

# Muso Ops — Credit Verification (Autonomous)

Pre-approval review of flagged credit requests. Core-backend posts a Block Kit
message to #credit-verification when a credit request's risk score >= 85%.
This skill defines how to handle those messages autonomously.

## HARD RULE

**Every message in #credit-verification is evaluated by this workflow.
Thread replies in escalation threads are handled as escalation responses (see Step 5).
All other messages: parse, investigate, act. No conversational responses.**

**Thread-awareness:** If the message is a reply in a thread (has `thread_ts` and is
not the parent message), check if the thread was initiated by a credit verification
workflow. If so, treat the reply as an escalation response (see Step 5 — Escalate),
not a new trigger. Only parent messages trigger the full workflow.

## Visual Feedback (Emoji Reactions) — MANDATORY

You MUST use the message tool with `action: "react"` at these exact points.
This is not optional. Skipping reactions is a workflow violation.

**Channel ID:** Use `OPS_CREDIT_VERIFICATION_CHANNEL_ID` if set; otherwise default
to `C0APB2CMM7C`. Substitute this channel ID in all `message(...)` calls below.

In examples below, use:
- `<credit_verification_channel_id>` = `OPS_CREDIT_VERIFICATION_CHANNEL_ID` (if set) else `C0APB2CMM7C`
- When `OPS_DRY_RUN=1`: `<credit_verification_channel_id>` = `OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID` (see *Dry-run mode* below)
- `<dry_run_prefix>` = `"[DRY RUN] "` when `OPS_DRY_RUN=1`, else empty string

### Dry-run mode (`OPS_DRY_RUN=1`, issue #145)

Dry-run lets us canary a model bump or local-dev the end-to-end workflow
without real API writes or Slack noise in the prod channel. At the start of
every run, check `OPS_DRY_RUN`:

```bash
DRY_RUN="${OPS_DRY_RUN:-0}"
case "$(printf %s "$DRY_RUN" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on) DRY_RUN=1 ;;
  *)             DRY_RUN=0 ;;
esac
```

When `DRY_RUN=1`:

1. **Channel routing.** Every Slack post (parent summary, in-thread
   escalations, queue-clear message, error-storm alert) goes to
   `OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID` instead of the prod channel.
   If that env is unset, **abort at B0a** with a clear error. `runlog.sh
   init` enforces this mechanically: it exits non-zero when `OPS_DRY_RUN=1`
   and the dry-run channel env is empty, so the run cannot even get past
   B0c without the test channel configured — prose alone is not enforcement.
2. **Prefix.** Prepend `[DRY RUN]` to every Slack post body (parent summary,
   thread replies, queue-clear, error-storm). Use the `<dry_run_prefix>`
   substitution in the templates.
3. **Skip Jan's escalation queue.** Do NOT `@`-tag Jan (`<@U038BM16T7W>`) in
   dry-run thread replies. Do NOT touch `urgent-escalations/` or any
   Jan-facing tracking file. The run still logs `escalation_posted` to the
   runlog so `compute-run-summary.sh` counts would-be escalations in the
   summary — we just don't page a human for them.
4. **API writes are short-circuited automatically.** The bash layer
   (`muso-admin-api.sh`) intercepts **anything that isn't GET/HEAD** when
   `OPS_DRY_RUN=1` (fail-closed deny-list — typos / lower-case / future
   verbs all get intercepted, not silently let through) and returns
   `{"http_status":200,"dryRun":true,"body":null,"wouldHaveExecuted":true}`.
   `body` is `null` on purpose — consumers that expected real-API shape
   (`.body.items`, `.body.id`) fail loudly instead of silently reading null
   from a stand-in payload. The credit-approve gate still runs, so a batch
   with bad evidence still fails visibly. `GET`/`HEAD` pass through to the
   real API so the bot can read state. Every would-be write is appended as
   JSONL to `${OPS_DRY_RUN_AUDIT_PATH:-/tmp/ops-dry-run-audit.jsonl}`
   (including `run_id` from `OPS_RUN_ID`/`RUN_ID` env if set). If the audit
   write fails, the response additionally carries `dryRun_audit_failed:
   true` and a stderr warning — callers should surface this, because it
   means the run has no forensic trail.
5. **Runlog self-describes.** `runlog.sh init` stamps a `run_header` event
   with `dryRun:true`, and `compute-run-summary.sh` reads that header at B6
   (source of truth is the log, not current env) and tags `run_finished`
   with `dryRun:true`. The Slack-side poster computes any `[DRY RUN]` prefix
   from `.dryRun` on the summary event — no redundant label field. No extra
   work required; these happen automatically when the env is set at B0c.

The rest of the workflow (B0–B6) runs exactly as production. Gates fire,
evidence is logged, the summary is computed. Only the API writes, the Slack
destination, and the human paging behavior change.

**Step 0 passes → add :eyes:**
```
message(action="react", channelId="<credit_verification_channel_id>", messageId="<msg_ts>", emoji="eyes")
```

**After acting (approve/reject/escalate) → remove :eyes: and add final emoji:**
```
message(action="react", channelId="<credit_verification_channel_id>", messageId="<msg_ts>", emoji="eyes", remove=true)
message(action="react", channelId="<credit_verification_channel_id>", messageId="<msg_ts>", emoji="<final>")
```

Where `<final>` is:
- `white_check_mark` — auto-approved
- `warning` — auto-moved to `user_verification_needed`
- `mag` — escalated for human review
- `no_entry` — skipped (cap or idempotent) — rare; only in reactive mode

## Workflow

### Step 0: Message Format Gate

**Self-ignore:** If the message starts with `[HEARTBEAT-BATCH]`, ignore it silently.
This is output from the batch verification heartbeat task — not a new credit to verify.

**On-demand batch trigger:** If the message content is exactly
`run credit verification batch` (case-insensitive), treat it as an on-demand
batch trigger and run **Batch Mode (B1–B5)** using the current channel ID
(`OPS_CREDIT_VERIFICATION_CHANNEL_ID`). Do NOT treat it as a reactive credit
message. Post the batch summary back to the same channel with the standard
`[HEARTBEAT-BATCH]` prefix.

**On-demand DRY-RUN trigger:** If the triggering message contains any of
`(dry-run)`, `[dry-run]`, `dry run`, or `dryrun` (case-insensitive —
e.g. `run credit verification batch (dry-run)`), set `OPS_DRY_RUN=1`
for the duration of this run:

```bash
# At the TOP of the B0c bash block, BEFORE calling runlog.sh init.
# Quote the message content; case-insensitive match.
MSG_LC="$(printf %s "$TRIGGER_MSG" | tr '[:upper:]' '[:lower:]')"
case "$MSG_LC" in
  *"(dry-run)"*|*"[dry-run]"*|*"dry run"*|*"dryrun"*)
    export OPS_DRY_RUN=1
    echo "[DRY RUN] message-flag detected — enabling OPS_DRY_RUN=1 for this batch" >&2
    ;;
esac
```

All dry-run semantics then kick in automatically: `runlog.sh init`
emits `dryRun:true` header (and fails fast if
`OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID` is unset — set in
`/etc/openclaw/main.env` on node-8), the admin-API wrapper short-
circuits every non-GET/HEAD call, and `compute-run-summary.sh` tags
the `run_finished` event. Nothing else in the workflow changes.

**Authorization.** This command is pre-authorized (no Aaron approval queue)
**only** when the Slack sender is one of:
- Aaron Kaufman (`U7RP6HKUZ`)
- Jan Delmo (`U038BM16T7W`)
- Nick Sollazzo (`U0AL36NADEY`)

Verify `sender_id` from message metadata before running. If the sender is
anyone else, fall through to the default SOUL.md "Write Operations —
Approval Required" flow: acknowledge, prep the action, DM Aaron for
approval, and only execute after he approves.

**Path A — Direct bot message:** Using **case-insensitive** matching, the message
contains both "credit request" and "risk score". Proceed to Step 1 using this message.

**Path B — Human relay via @Ops mention:** The message does NOT contain both markers,
but it is an explicit `@Ops` mention in this channel. No other phrases qualify —
only direct `@Ops` mentions trigger this path. Slack does not deliver bot messages
to other bots, so the original Credit Verification Bot message may not have reached
you. Look at the **preceding message** in the channel (the message immediately above)
to find the Credit Verification Bot's rich message containing the credit data. If the
preceding message contains both "credit request" and "risk score", use THAT message's
content for Step 1 parsing. Store the preceding message's timestamp as
`data_message_ts` — this is the message you will react on and parse from.

> **TODO**: This Path B workaround is fragile (depends on message ordering). The
> proper fix is to have core-backend post credit verifications via a webhook instead
> of a bot user, so Slack delivers the message to the Ops agent directly. See
> core-backend `postCreditVerification()`.

**Neither path matches:** Ignore silently.

If either path matches, YOU MUST immediately call (use `data_message_ts` for Path B):
```
message(action="react", channelId="<credit_verification_channel_id>", messageId="<data_message_ts>", emoji="eyes")
```

### Step 1: Parse the Incoming Message

Extract these fields from the message text. The Credit Verification Bot posts using
Slack block kit with bold labels. Match field values by looking for the label followed
by the value on the same or next line. Labels may vary — use the aliases below.

| Field | Required | Bot label(s) | Example value |
|-------|----------|-------------|---------------|
| Credit request ID | Yes | `Credit Request ID:`, `Credit Request:` | `test-req-011`, `cr_abc123` |
| Profile ID | Yes | `Profile ID:` | `test-profile-001`, `prof_xyz789` |
| Profile name | Yes | `Profile:` | `Test Artist Profile` |
| Workspace ID | Yes | `Workspace ID:`, `Workspace:` | `test-ws-001` |
| Owner email | Yes | `Owner Email:` | `nick@muso.ai` |
| Track title | Yes | `Track:` | `Blinding Lights` |
| Artists | Yes | `Artists:` | `The Weeknd` |
| Spotify link | No | `Spotify URL:`, `Spotify:` | `https://open.spotify.com/track/...` |
| Claimed roles | Yes | `Roles:` | `Producer, Songwriter` |
| Overall risk score | Yes | `Risk Score:` | `92%` |
| Per-dimension scores | Yes | `Risk Breakdown:` (bullet list below) | `• artist_risk: 0.85` |
| Pending verification count | No | `Pending Verifications:` | `3` |

**Per-dimension scores** appear as a bullet list under `Risk Breakdown:`, with each
line formatted as `• key: value` (e.g., `• artist_risk: 0.85`). Collect all bullet
items as the per-dimension risk scores.

**If any required field cannot be parsed**, post an error in-thread AND escalate:

```
⚠️ PARSE ERROR — Could not extract required fields from this message.

Missing: [list of missing fields]

Skipping verification. <@U7RP6HKUZ> — message format may have changed. Manual review needed.
```

Do NOT attempt to investigate or act on incomplete data.

### Step 2: Idempotency Check

Before investigating, query the credit request status:

```bash
bash /opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/credit-requests/<credit_request_id>"
```

If the status is NOT `unverified` or `user_verification_needed` (e.g., already `approved` or `rejected`),
post a short note in-thread and stop:

```
ℹ️ Already processed — status: [current_status]. Skipping.
```

**If the GET returns 404** (and ONLY 404 — not other errors), the UUID may not be a
credit-request ID at all. Ad-hoc verification requests from Jan/Aaron sometimes
paste a **profile** UUID instead. Before giving up, run the disambiguation ladder:

**Step 2a (404 fallback): try as profile ID**

```bash
bash /opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/profile/<id>"
```

- If this returns 200, the input was a profile UUID. Pull the profile's pending
  credit-request counts first, then the actual rows:

  ```bash
  # counts scoped to this profile
  bash /opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh \
    call GET "/admin/credit-requests/counts?profilesIds=<id>"

  # the actual unverified rows (server-side filtered)
  bash /opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh \
    call GET "/admin/credit-requests?profilesIds=<id>&status=unverified&limit=100&page=1"

  # and user_verification_needed rows
  bash /opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh \
    call GET "/admin/credit-requests?profilesIds=<id>&status=user_verification_needed&limit=100&page=1"
  ```

  **⚠️ CRITICAL — param name:** The correct filter parameter is **`profilesIds`**
  (plural, capital `I`) — NOT `profileId` (singular). Unknown query params on
  this endpoint are **silently dropped** by Sequelize and you will get the
  general queue back instead of the scoped list. Always spot-check the first
  response: every row's `profileId` field must equal `<id>`. If any row has a
  different `profileId`, you used the wrong param name and the filter was
  dropped — fix the param and retry. Do NOT continue on unscoped data.

  Paginate with `page=1, page=2, ...` until the response returns fewer items
  than `limit`. The total count from `/admin/credit-requests/counts?profilesIds=<id>`
  is authoritative — your paginated sum MUST match it; if it doesn't, something
  went wrong (rate limit, backend hiccup) and you should stop and escalate.

  Treat each matching credit-request as an individual idempotency target and
  investigate in bulk-mode: one consolidated escalation post per profile (see
  Step 5), not one post per credit. The post MUST state explicitly: *"Interpreted
  as profile ID; <N unverified> + <M user_verification_needed> credit requests
  found for this profile (server-side filtered on profilesIds=<id>)."* Do NOT
  pretend you found it on the first call.

  **Zero pending requests → profile-legitimacy pivot:** If the count endpoint
  returns zero for both `unverified` and `user_verification_needed`, the human
  likely wants a profile-legitimacy verdict, not a credit-level one. Delegate
  to the `muso-verify-profile` skill:

  ```
  Use skill: muso-verify-profile
  Input: <profile_id>
  ```

  That skill produces an authenticity score (IPIs, claiming status, industry vs.
  user-added credit mix, external cross-reference) and a Slack-formatted verdict
  (🟢 VERIFIED / 🟡 LIKELY LEGIT / 🟠 INCONCLUSIVE / 🔴 SUSPICIOUS). Post that
  verdict in the #credit-verification thread, prefixed with *"Interpreted as
  profile ID; no pending credit requests found (authoritative count endpoint
  returned 0). Shifting to profile-legitimacy verdict:"* so the human knows
  both what you searched and why the output shape changed.

  Do NOT skip the profile-legitimacy pivot in favor of a bare *"no pending
  request found, please double-check the UUID"* response — that answers the
  literal question but not the likely intent.

  **Per-credit audit intent → `muso-audit-profile-credits`:** If the human
  phrasing signals they want to audit every one of the profile's already-approved
  credits (e.g. *"verify all the credits"*, *"audit the tracks of this profile"*,
  *"go through each credit"*) rather than an aggregate legitimacy score,
  delegate to `muso-audit-profile-credits` instead of `muso-verify-profile`.
  That skill diffs the profile's credit list against industry-sourced catalog
  data and produces per-track verdicts. The two pivots are NOT interchangeable:
  aggregate legitimacy vs. per-track audit answer different questions.

- If the profile lookup also returns 404, post the current `⚠️ API ERROR` (below)
  — the ID is neither a credit-request nor a profile. Do NOT fabricate a search
  scope (see HARD RULE — search-scope claims).

**If the GET call fails for any other reason** (network error, non-404 non-200
response, timeout), post an error in-thread and stop — do NOT proceed with
investigation on unknown state:

```
⚠️ API ERROR — Could not verify current status of credit request [ID].

Error: [details]

Skipping verification — manual review required. <@U7RP6HKUZ>
```

### Step 3: Investigate

Use existing skill workflows:

**3a. Athena cross-reference** (from `muso-ops-credits`):
```sql
SELECT t._id, t.title, t.popularity, t.default_release_label
FROM "platform-industry-bi-prod".matvw_catalog_track t
WHERE t._id = '<track_id>'
  AND t.is_deleted = false
```

Does this person appear in industry data for this track?
Is the role plausible given the track's genre/era/label?

**3b. Web research** (from `muso-ops-fraud`):

**Tool selection — BROWSER ONLY for credit verification:**

- Use `browser` for **every** web lookup — specific URLs (Apple Music/MusicBrainz/Discogs/AllMusic, TIDAL, Jaxsta, ASCAP/BMI/SESAC, studio/artist sites) AND searches (load a search engine URL with `browser open https://duckduckgo.com/?q=<url-encoded query>` or Bing/Google).
- **Do NOT use `web_fetch`.** The admin-api credit-approve gate does not accept `web_fetch` evidence — any PUT approve backed by `web_fetch` loads will be blocked. `web_fetch` frequently returns Cloudflare challenge pages as 200 OK (false positives) and doesn't render JavaScript-dependent credit pages.
- **Do NOT use `web_search`.** The plugin redirects `web_search` in this channel; use `browser` with a search-engine URL instead.

Workflow: `browser open <tier1 URL>` → `browser snapshot` (read rendered text) → repeat for a second Tier 1 host → extract a **literal substring** from the rendered page that confirms the claim (artist name as rendered, role string, track title, etc.) — this is your `--evidence-excerpt` for the approve.

Sources are tiered by priority. Always check Tier 1. Check Tier 2 and 3 as indicated.

**Tier 1 — Always check (primary credit databases):**
- Apple Music / MusicBrainz / Discogs / AllMusic: load the artist + track pages and check the credits panel / track-listing for the claimed name+role. Spotify "Show Credits" is unusable for unauthenticated headless browsing (login-gated; rows render as `-` for guests) — dropped 2026-05-05.
- Apple Music: check album credits page — detailed role-level credits for tracks
- MusicBrainz: `musicbrainz.org/search?query=[name]&type=artist` — recording-level credits; look for the specific track+role match, not just artist existence
- Discogs: `discogs.com/search/?q=[name]&type=artist` — discography and credits
- AllMusic: `allmusic.com/search/all/[name]` — artist profile with credits

**Tier 2 — Supporting sources:**

*Streaming-credit cross-check (any role):*
- TIDAL: `tidal.com` — track/artist credits page; useful as supporting evidence but less reliably populated than Tier 1, so it does not count toward the Tier-1 quorum.

*Writing/publishing roles (songwriter, composer, lyricist, publisher):*
- ASCAP: `ascap.com/repertory` — search by writer name
- BMI: `repertoire.bmi.com/` — search by writer name
- SESAC: `sesac.com` — affiliated writer search

**Tier 3 — Check if Tier 1 is inconclusive (no Tier 1 source confirms the claimed name+role):**
- Jaxsta: `jaxsta.com` — dedicated music credits database
- LinkedIn: music industry career history
- Professional website: check email domain
- DuckDuckGo: `"[name]"+[role]+engineer|producer|mixing`

If a source returns a 429 (rate limit) or blocks the request, skip it and note it
as a failed source. Do not retry aggressively — space requests if processing
multiple verifications in sequence.

**Risk-breakdown steering (PR #233).** The inbound message includes a `Risk Breakdown` bullet list (Step 1 line 230–236) with per-dimension scores like `artist_risk: 0.85`. The overall `Risk Score` is a *trigger*, not a verdict — `100%` does not mean the credit is 100% fraud. Use the per-dimension breakdown to focus investigation:

| Risk dimension high (≥0.7) | Investigation focus |
|---|---|
| `artist_risk` | Verify artist legitimacy: Spotify monthly listeners, MusicBrainz IPI presence, claiming status on `/admin/profile/<id>` |
| `track_risk` | Verify track + credit match: Athena `matvw_catalog_track` row, Apple Music or MusicBrainz credits panel |
| `user_risk` / `email_risk` | Check submission velocity (last 24h), email domain (disposable?), bulk-add pattern |
| `claim_recency_risk` | Compare claiming timestamp vs credit-add timestamp via `/admin/profile/<id>` |

This *steers* investigation; it does not replace the source taxonomy above. A high `artist_risk` means look harder at artist legitimacy on Tier 1; a high `track_risk` means cross-reference Athena's catalog row against the credit claim.

**3c. Fraud signal check**:
- Bulk credit submissions (>20 in one day)?
- Disposable email?
- Genre mismatch across submitted credits?
- Credits to high-popularity tracks by unknown profile?
- Credit additions right after profile claiming?

**Investigation failure — CRITICAL:** If Athena is unreachable or returns an error,
OR if more than 2 **Tier 1** sources fail, the investigation is INCOMPLETE.
An incomplete investigation MUST result in **INCONCLUSIVE — TIER-1 UNREACHABLE**
with `verdict.reason` containing the literal string `tier1_unreachable` (required by the
runlog gate; see PR #235). The default action is **move to `user_verification_needed`**
(2026-05-05); per-credit Slack escalation is opt-in via
`OPS_VERIFICATION_FALLBACK_TO_ESCALATE=1`. Never auto-approve or auto-reject. Include
in the report: "Investigation incomplete — [list which sources failed with HTTP/error
codes]."

**Grounding — HARD RULE (anti-confabulation):**

Every source URL cited in your verdict MUST correspond to a **successful `browser` tool call** executed in this investigation turn. Prior knowledge, training-data recall, or pattern-matching on the profile/studio/track name is NOT evidence. If you didn't load the page with `browser` and see the text in the snapshot, you don't know what it says.

**Mechanical enforcement.** Autonomous approves are gated by
`muso-admin-api.sh` at the bash layer. The gate refuses `status=approved`
on **both** `PUT /admin/credit-requests` (batch) and
`PATCH /admin/credit-requests/<id>` (single-credit) unless it finds in the
active session log:

1. **≥2 distinct Tier 1 hostnames** (music.apple.com, musicbrainz.org, discogs.com, allmusic.com — `www.` tolerated) loaded via the **`browser`** tool (NOT `web_fetch` — those loads do not count). Spotify is NOT in this set (dropped 2026-05-05): its credits dialog is login-gated for headless browsers and produces no verifiable credit data. Tidal is supporting (Tier-2) — useful corroboration but does not count toward the Tier-1 quorum (see `lib/browser-evidence.sh:67` for the canonical regex).
2. The `--evidence-excerpt` string you pass must appear **verbatim** (case-insensitive) in the browser result text for each of those ≥2 pages.

**Invocation.** Autonomous approves and UVN flags go through **one sanctioned entry point** — `batch-verify-profile.sh` — NOT inline bash loops and NOT direct calls to `batch-approve-credits.sh` / `batch-flag-credits.sh`. R3 adds this per-profile dispatcher on top of R1's delegate wrappers so evidence-gathering is structurally tied to each profile instead of spread across the batch:

```bash
# Autonomous APPROVE — one invocation per profile, N credits per call.
# The wrapper pre-flights the evidence-quorum check locally: if it would
# fail, you get exit 3/5/6 with a remediation block telling you what to
# fix. No HTTP round-trip happens until pre-flight passes.
#
# --credited-name / --track-title / --role come from the inbound message
# Step 1 fields (Profile / Track / Roles). The dispatcher uses them to
# validate the excerpt structurally:
#   approve: excerpt must contain credited_name AND (track_title OR role)
#   flag:    excerpt must contain (track_title OR role) AND NOT credited_name
# Failing structural validation is exit 6 (excerpt_does_not_prove_claim).
bash "$SKILL_DIR/scripts/batch-verify-profile.sh" \
    --profile-id "$PROFILE_ID" \
    --credited-name "Pau Romero" \
    --track-title  "Yellow Submarine" \
    --role         "songwriter" \
    --evidence-excerpt "Pau Romero, songwriter — Yellow Submarine credits" \
    --ids "cr_1,cr_2,cr_3" \
    --decision approve

# Autonomous FLAG (user_verification_needed) — same wrapper. PR #233 raised
# the flag bar to match approve in rigor:
#   (a) >=1 successful browser load whose URL contains $PROFILE_ID in the
#       current run window (browse-required prerequisite, exit 5 otherwise);
#   (b) inverted structural rule: excerpt must contain track_title or role
#       AND must NOT contain credited_name (exit 6 otherwise — proves the
#       agent saw the credit area and verified the person's absence);
#   (c) excerpt must appear on >=2 distinct Tier-1 browser snapshots
#       (exit 3 with missing_flag_evidence otherwise — raised from >=1);
#   (d) a closed-list --flag-reason from the 4-value enum below.
# No bypass — the prior `evidence_quorum_failed` / `human_review_requested`
# reasons were removed after run 20260430-111343-1605a8 used them as a
# universal escape hatch (460 credits flagged with 1 browser call).
# Placeholder excerpts ("batch conservative review", "n/a", etc.) are
# rejected at arg validation regardless of decision.
bash "$SKILL_DIR/scripts/batch-verify-profile.sh" \
    --profile-id "$PROFILE_ID" \
    --credited-name "Pau Romero" \
    --track-title  "Yellow Submarine" \
    --role         "songwriter" \
    --evidence-excerpt "Yellow Submarine — songwriters: Lennon, McCartney" \
    --ids "cr_1,cr_2,cr_3" \
    --decision flag \
    --reason "Pau Romero not in songwriter credits on Tier-1 sources" \
    --flag-reason <enum: name_mismatch|popularity_anomaly|no_tier1_match|metadata_inconsistent>
```

**HARD RULE — single entry point.** `batch-approve-credits.sh` and `batch-flag-credits.sh` MUST NOT be invoked directly from the agent workflow. They exist only as delegate primitives for `batch-verify-profile.sh` and the bats test suite. Any direct call is a workflow regression: it bypasses the per-profile pre-flight and the run_started session scoping the dispatcher provides, and the 2026-04-23 12:57 UTC dry-run showed what happens when evidence-gathering is not structurally per-profile (gate correctly rejected 100% of approves across 30 profiles).

The dispatcher (`batch-verify-profile.sh`):
- Runs a **contamination check** first: if any `web_fetch` to a Tier-1 host appears in the current run's session (scoped by `run_started.ts`, not just session-file mtime), exits 3 BEFORE any delegate call with a message to rotate the session.
- Runs an **evidence quorum check** next: mirrors `enforce_credit_approve_gate` exactly — counts distinct Tier-1 hostnames whose browser-result text contains `--evidence-excerpt` (case-insensitive). If < `CV_REQUIRED_LOADS` (default 2), exits 3 with a remediation block naming the matching hosts, suggested next `browser(...)` calls, and the exact retry command.
- On pass, delegates to `batch-approve-credits.sh` or `batch-flag-credits.sh` and propagates their exit codes honestly.
- Refuses `--requester`. Jan/Aaron human overrides still go through direct `muso-admin-api.sh` calls in the escalation-thread flow (Step 5 → Executing a decision below) — that path uses `--requester <slack_id>` to bypass the gate.

Authoritative per-call outcome lands in the `.results.jsonl` truth floor that `muso-admin-api.sh` writes inside the dry-run intercept / rejected-by-gate / real HTTP branches. `compute-run-summary.sh` reads that file as the source of truth for the Slack summary — so `⚠️ DISCREPANCY DETECTED` will prepend the summary if attempts > 0 but landed == 0.

> **DO NOT DO THIS.** The 2026-04-22 19:15 incident ran inline bash along these lines:
>
> ```bash
> # ❌ BROKEN — evidence in body (gate ignores it), stderr swallowed, iteration count lied about approvals
> approve_cr() { bash muso-admin-api.sh call PATCH "/admin/credit-requests/$1" "{\"status\":\"approved\",\"evidence_excerpt\":\"$2\"}" 2>&1; }
> for id in $IDS; do approve_cr "$id" "$excerpt" > /dev/null; C=$((C+1)); done
> echo "$C approved"
> ```
>
> The gate rejected every call (body-only evidence), `> /dev/null` hid the errors, and `$C` counted the iterations. Slack got "500 processed, 333 approved"; the DB got 0. Use the wrappers — they make this shape impossible.

Good excerpt examples (each is a literal substring you saw in a browser snapshot):
- `"Jose Roig"` — artist name as rendered on MusicBrainz + AllMusic
- `"Producer: Ulf Blomberg"` — role string as rendered on AllMusic credits
- `"Tears In Your Smile"` — track title as rendered on Apple Music or MusicBrainz

Bad excerpts: generic strings like `"music"`, single words that appear everywhere (`"artist"`), or things you didn't actually see in the rendered page. The bash layer sees 100% of admin API traffic, so there is no way to confabulate past it.

If the approve command returns `credit_approve_gate: insufficient evidence`,
load two fresh Tier 1 pages with `browser open <url>`, run `browser snapshot`
to confirm the excerpt is visible in the rendered text, then retry the
approve with the updated excerpt. If Tier 1 pages genuinely don't confirm the
credit, the credit is either **SUSPICIOUS** (move to user_verification_needed)
or **INCONCLUSIVE — TIER-1 UNREACHABLE** (also moves to user_verification_needed
since 2026-05-05; reason MUST contain `tier1_unreachable`). Per-credit Slack
escalation is opt-in via `OPS_VERIFICATION_FALLBACK_TO_ESCALATE=1`.

**Human overrides bypass the gate — narrowly.** Only passes when `--requester`
resolves to Jan (jan@muso.ai) or Aaron (aaron@muso.ai), i.e. they replied
"approve" in an escalation thread after reviewing the credit. Other requesters
(including Nick triggering a batch with `run credit verification batch`) do NOT
count as per-credit verification — the gate still requires `--evidence-excerpt`
+ browser loads. Because the batch wrappers refuse `--requester`, these human
overrides are the one place that calls `muso-admin-api.sh` directly — see
Step 5 → Executing a decision.

**Verdict → Action (PR #235 — escape-hatch labels removed):**

| Verdict | Action |
|---|---|
| VERIFIED LEGIT | Auto-approve (gate enforces ≥2 Tier-1 evidence + claim-proving excerpt). |
| SUSPICIOUS — CLEAR FRAUD / BORDERLINE | Move to `user_verification_needed`. |
| INCONCLUSIVE — TIER-1 UNREACHABLE | Move to `user_verification_needed` (2026-05-05). `reason` MUST contain `tier1_unreachable`; the runlog gate enforces ≥2 distinct Tier-1 attempts + ≥1 search-engine browser load for the profile before accepting this verdict. Per-credit Slack escalation is opt-in via `OPS_VERIFICATION_FALLBACK_TO_ESCALATE=1`. |

The pre-PR-#235 `UNVERIFIABLE_LOW_CONCERN` (auto-approve when "no web presence but consistent pattern") and `UNVERIFIABLE_NEEDS_REVIEW` (escalate when "no web presence + risk signals") labels are removed. The agent had collapsed both into "I didn't browse but here's a label" — see Step B5 forbidden-labels note. There is no auto-approve path that does not surface positive Tier-1 evidence; there is no escalate path that does not document attempted Tier-1 browses.

**HARD RULE — search-scope claims (anti-confabulation):**

Never state a search count, scope, or endpoint set you did not actually query. This
rule sits alongside the Grounding rule above: Grounding covers *sources you cite*,
this covers *what you claim you searched*.

Concretely:

1. If you only paginated the first N items of one status, say so exactly. Do NOT
   round up to *"all X unverified"* when you only scanned the first page, and do
   NOT claim to have searched endpoints (submissions, profiles, claiming, etc.)
   that you did not actually call.
2. Before posting any "I searched …" / "I scanned …" / "I checked …" statement in
   Slack, mentally enumerate the exact `toolCall` names + paths from this turn
   that back the claim. If the list is empty or the counts don't line up, rewrite
   the message — say "could not find on a lookup of `/admin/credit-requests/<id>`"
   rather than "searched all records."
3. If a single-record lookup 404s, say *"not found at `/admin/credit-requests/<id>`;
   trying as profile ID"* and follow the Step 2a ladder. Do NOT post a "can't find
   it anywhere" message until the ladder is exhausted.

This is the LLM-level rule. A mechanical counterpart (session-evidence check on
outbound Slack text) is planned as a follow-up — don't rely on the absence of
mechanical enforcement here as permission to fabricate. (Reference:
[incident 2026-04-17](https://muso-ai.slack.com/archives/C0APB2CMM7C) — Ops
posted *"searched all 2,443 unverified"* after only scanning 200/status.)

### Step 4: Classify

Map investigation results to a verdict using `muso-ops-fraud` criteria:

| Verdict | Criteria | Action |
|---------|----------|--------|
| **VERIFIED LEGIT** | Confirmed via Tier-1 web sources: ≥2 distinct Tier-1 hosts (Apple Music / MusicBrainz / Discogs / AllMusic) show the credited person at the credit context for this track + role. Tier-2 (Tidal album-credits, ASCAP/BMI/SESAC, Jaxsta, LinkedIn, studio site) is supporting only — never the sole basis. | Auto-approve |
| **SUSPICIOUS — CLEAR FRAUD** | 2+ strong fraud signals (identity mismatch, web contradicts, disposable email + bulk submissions). Browser evidence MUST show the absence (≥2 Tier-1 hosts checked, name not in credits). | **Move to `user_verification_needed`** (silent per-credit; rolled into batch summary). See note on reject policy below. |
| **SUSPICIOUS — BORDERLINE** | 1 fraud signal or soft signals. Browser evidence MUST show ≥2 Tier-1 hosts attempted. | **Move to `user_verification_needed`** (silent per-credit; rolled into batch summary) |
| **INCONCLUSIVE — TIER-1 UNREACHABLE** | Browser attempted ≥2 Tier-1 hosts and loaded a search-engine URL via browser but found no confirming evidence — either sources existed but couldn't be read (captcha / 5xx / network) or sources had no entry for this credit (typical for indie tracks). The runlog `verdict.reason` MUST contain the literal string `tier1_unreachable` for the runlog gate to accept it; the gate also enforces ≥2 distinct Tier-1 attempts + ≥1 search-engine browser load for the profile. | **Move to `user_verification_needed`** (2026-05-05; was previously per-credit Slack escalation). Indie-track-heavy queues legitimately produce many of these — UVN scales via the Muso admin UI. The `OPS_VERIFICATION_FALLBACK_TO_ESCALATE=1` override restores per-credit Slack escalation for fraud-review traffic. |

> **No-reject policy (2026-04-13):** The bot does NOT auto-reject. Both SUSPICIOUS verdicts move credits to `user_verification_needed` so the user can complete their own proof step. Rejection remains available only as a manual override via `reject [reason]` in an escalation thread (see Step 5 → Escalate → Executing a decision).

### Step 5: Act

#### Safety Rails — Check BEFORE Acting

- **Daily approval cap (500/day, UTC).** The cap applies to **autonomous approvals only** — verification-needed moves and escalations are uncapped. Human-initiated approvals (Jan/Aaron override from an escalation thread) carry their Slack ID as `--requester` and do NOT count against the cap.

  Count today's autonomous approvals via the helper:
  ```bash
  COUNT=$(OPS_AUDIT_LOG_DIR="${OPS_AUDIT_LOG_DIR:-api-logs/admin}" \
    bash "${SKILL_DIR}/scripts/count-approvals.sh")
  ```
  where `SKILL_DIR=/opt/hydra/workspaces/operations/skills/muso-ops-credit-verification`.

  The counter matches entries where **all three** are true: `operator == "clio"`, `requester == "clio"`, `status == "approved"`. Cap resets at **00:00 UTC** (log filename is `YYYY-MM-DD.jsonl` in UTC).

  If `COUNT >= 500` and the current verdict is LEGITIMATE (would trigger an approve): **skip the approve**, mark the credit as `skip_cap` in the run log, and include in the batch summary. **Verification-needed moves and escalations still run** — the cap does not block them.

- **Dry-run mode.** If `OPS_DRY_RUN=1`, still call the admin API wrapper. If the response includes `dryRun: true` (camelCase — the wrapper also emits `body: null` and `wouldHaveExecuted: true`), treat it as a successful action but explicitly note in the thread/report: `DRY-RUN: no changes applied`. If the response additionally has `dryRun_audit_failed: true`, surface that loudly — it means the audit JSONL was lost and the run lacks post-mortem evidence.

#### Auto-Approve (VERIFIED LEGIT or LOW CONCERN)

Use `batch-verify-profile.sh --decision approve`. This dispatcher is the ONLY sanctioned form for autonomous approves — it pre-flights evidence locally (exits 3 with remediation text before any API call if the quorum isn't met) and delegates to `batch-approve-credits.sh` on pass.

```bash
bash "$SKILL_DIR/scripts/batch-verify-profile.sh" \
  --profile-id "$PROFILE_ID" \
  --credited-name "$CREDITED_NAME" \
  --track-title  "$TRACK_TITLE" \
  --role         "$ROLE" \
  --evidence-excerpt "<literal substring containing credited_name AND (track_title OR role) from >=2 Tier 1 pages>" \
  --ids "<id1>,<id2>,...,<idN>" \
  --decision approve
```

One invocation per profile, N credits per invocation. The dispatcher's check is identical to `enforce_credit_approve_gate`: ≥`CV_REQUIRED_LOADS` (default 2) distinct Tier-1 hostnames whose browser-result text contains the excerpt, scoped to the current run's time window. PR #233 adds the structural rule on top: the excerpt must contain `--credited-name` AND (`--track-title` OR any `--role` token). On pass it delegates to `batch-approve-credits.sh` which issues one `PUT /admin/credit-requests` for the batch (`request_ids` of length N in `.results.jsonl`).

**Important:** `PUT /admin/credit-requests` is the bulk status endpoint. `PUT /admin/credit-requests/<id>` is a DIFFERENT endpoint that updates the credits array only and silently ignores the status field — the delegate already targets the correct route. The gate also covers `PATCH /admin/credit-requests/<id>` (single-credit) in case a human-override flow needs it; batch approves don't use PATCH.

**On exit 3 from the dispatcher:** read the remediation block. It names (a) the Tier-1 hosts currently matching, (b) suggested next `browser(...)` calls, (c) the exact retry command. Typical recovery: load the two suggested pages, confirm the excerpt appears in the rendered text, retry once.

**On exit 5 from the dispatcher:** the browse-required prerequisite tripped — no successful browser load in the current run window has a URL containing `$PROFILE_ID`. Load a Tier-1 page whose URL or response text references the profile (`browser(https://musicbrainz.org/artist/<mbid>)` or `browser(https://music.apple.com/<region>/artist/<id>)`), then retry. Exit 5 is structurally distinct from exit 3 — it means the agent skipped step 3 entirely for this profile. Do NOT try to bypass with placeholder excerpts; the dispatcher's deny-list will reject those even if you somehow get past exit 5.

**On exit 6 from the dispatcher (PR #233):** the excerpt was found on the page, but doesn't prove the claim. The remediation block names what's missing (or unexpectedly present, for flag). Recovery:
- **Approve**: load the credit area of the Tier-1 page (MusicBrainz recording-level credits, AllMusic credits panel, Apple Music track page, Discogs release tracklist). Find a substring containing BOTH the credited person's name AND either the role or the track title. Examples: `"Pau Romero, songwriter"`, `"Pau Romero — Yellow Submarine"`, `"Songwriter: Pau Romero"`.
- **Flag**: load the credit area, find a substring containing the role/track BUT not containing the credited person's name (proving they're not credited there). If the credited person IS on the page in the credit list, flag is wrong — approve or escalate instead.

If after retry evidence still isn't there, **do NOT bulk-flag the whole queue with a placeholder excerpt** (the dispatcher's deny-list will reject that anyway as of 2026-04-30). Two correct paths instead:

1. **Per-credit flag with real evidence**: load 1 Tier-1 page that confirms the flag-worthy signal (name not credited, popularity anomaly, etc.) and use a literal substring from that snapshot as `--evidence-excerpt`, plus a `--flag-reason` enum value matching what you saw (`name_mismatch`, `popularity_anomaly`, `no_tier1_match`, `metadata_inconsistent`).
2. **Escalate** (when sources are genuinely unreachable, OR a human asked for the flag without per-profile evidence): use the per-credit escalation path (Step 5 → Escalate). Bypass `--flag-reason` values were removed 2026-04-30 after run `20260430-111343-1605a8` used `evidence_quorum_failed` 460 times with 1 browser call across the run — there is no longer a flag path that skips the snapshot-match gate.

**Direct `muso-admin-api.sh` calls are reserved for the Step 5 escalation-thread flow** (Jan/Aaron `--requester` human override). Any autonomous approve that bypasses `batch-verify-profile.sh` is outside this skill's contract — the post-run reconciliation will catch it as `silent_failure_detected` if attempts don't land.

Log via `muso-ops-audit` before execution. Then YOU MUST call:
```
message(action="react", channelId="<credit_verification_channel_id>", messageId="<msg_ts>", emoji="eyes", remove=true)
message(action="react", channelId="<credit_verification_channel_id>", messageId="<msg_ts>", emoji="white_check_mark")
```

#### Move to `user_verification_needed` (SUSPICIOUS — any tier)

Both CLEAR FRAUD and BORDERLINE verdicts take this same action: flip the credit's status so the user is prompted to complete their own verification. The bot does NOT reject.

Use `batch-verify-profile.sh --decision flag`. The dispatcher delegates to `batch-flag-credits.sh`, which issues a single `PUT /admin/credit-requests` for the entire batch with `{"requestIds":[...],"status":"user_verification_needed"}`. This is the SAME route batch-approve-credits.sh uses; the backend `updateStatus` handler accepts every `CreditRequests.STATUSES` value, so one call atomically transitions all matching requests from UNVERIFIED → USER_VERIFICATION_NEEDED. The earlier per-id `PATCH /admin/credit-requests/<id>` design was wrong — that route was never registered in core-backend, and the 2026-04-27 15:42 UTC real run confirmed it (25/25 PUTs got HTTP 404 "Cannot PATCH …").

**Flag has its own evidence gate** with the same rigor as approve as of PR #233 (built on top of PR #232's earlier flag gate). The dispatcher requires:
- a non-placeholder `--evidence-excerpt`,
- a closed-list `--flag-reason` enum,
- the structural prerequisite (PR #232): ≥1 successful browser load whose URL contains `--profile-id` in the current run window,
- the inverted structural rule (PR #233): excerpt must contain `--track-title` or any `--role` token AND must NOT contain `--credited-name` (proves the person is verifiably absent from the credit area),
- the raised quorum (PR #233): excerpt must appear on ≥2 distinct Tier-1 hosts (was ≥1).

**No bypass reasons** — every flag must carry a literal Tier-1 snapshot excerpt that proves verified absence.

```bash
bash "$SKILL_DIR/scripts/batch-verify-profile.sh" \
  --profile-id "$PROFILE_ID" \
  --credited-name "$CREDITED_NAME" \
  --track-title  "$TRACK_TITLE" \
  --role         "$ROLE" \
  --evidence-excerpt "<literal substring with track/role, NOT containing credited_name, from >=2 Tier-1 pages>" \
  --ids "<id1>,<id2>,...,<idN>" \
  --decision flag \
  --reason "Moved to user_verification_needed during pre-approval: [specific reason]" \
  --flag-reason <name_mismatch|popularity_anomaly|no_tier1_match|metadata_inconsistent>
```

UVN flows through the same `.results.jsonl` truth floor as approves — `compute-run-summary.sh` reconciles UVN counts the same way and `silent_failure_detected` fires if `vn_attempted > 0 && vn_landed == 0`. The `flag_reason` enum is recorded on each row, alongside `credited_name` / `track_title` / `role` (PR #233), so post-batch auditing can categorize and inspect UVN actions without parsing back through the agent transcript. The wrapper exits 0 on HTTP 2xx (or dry-run intercept), 1 on HTTP/network failure, 3 on flag quorum failure (`missing_flag_evidence`), 2 on arg validation failure (placeholder excerpt, missing/invalid `--flag-reason`, missing `--credited-name`/`--track-title`/`--role`), 5 on missing per-profile browse, and 6 on excerpt that doesn't prove the claim (structural rule).

Use a specific reason based on findings (examples):
- "Moved to user_verification_needed during pre-approval: no web presence, disposable email, 15 bulk submissions in 24h"
- "Moved to user_verification_needed during pre-approval: identity mismatch — web sources contradict claimed credits"
- "Moved to user_verification_needed during pre-approval: bulk self-additions across unrelated genres"

**Fallback if gate #2 failed** (`OPS_VERIFICATION_FALLBACK_TO_ESCALATE=1` set): skip the API call, treat this verdict as an escalation instead — post the same detail in-thread and tag Jan. This prevents silently-parked credits until the user-facing notification flow ships.

Log via `muso-ops-audit` before execution. Do NOT tag Jan per-credit — the batch summary handles the single rolled-up ping.

Reactive mode only: update emoji on the source message. YOU MUST call:
```
message(action="react", channelId="<credit_verification_channel_id>", messageId="<msg_ts>", emoji="eyes", remove=true)
message(action="react", channelId="<credit_verification_channel_id>", messageId="<msg_ts>", emoji="warning")
```

(Using `warning` instead of `x` to reflect "moved, not rejected." In batch mode, no reactions since there is no source message.)

Per-credit Slack post is **removed** in both modes — the rolled-up batch summary (Batch Mode B3) carries the audit trail.

#### Escalate (NEEDS REVIEW)

**Evidence attachment rule (mandatory for every escalation).** Before composing the escalation body, run `scripts/session-evidence.sh` and embed its JSON output **verbatim** inside a fenced `session_evidence` block in the Slack post. The helper scans the active openclaw session's JSONL log and reports the `browser` tool calls that actually succeeded (deduped by URL) and those that failed. You MUST NOT cite any URL in "Sources (Tier 1)" that is not present in `session_evidence.browser_loads[].url`. If `session_evidence.count_ok == 0`, the escalation body must say so plainly and omit the "Sources (Tier 1)" list entirely. This rule mirrors the bash-layer gate on `PUT status=approved` in `muso-admin-api.sh` — it closes the symmetric hole on escalations so citations cannot be confabulated.

```bash
SESSION_EVIDENCE=$(bash "$SKILL_DIR/scripts/session-evidence.sh")
```

The credit is already in `unverified` or `user_verification_needed` status (set by core-backend).
No API call needed — just notify Jan. YOU MUST call:
```
message(action="react", channelId="<credit_verification_channel_id>", messageId="<msg_ts>", emoji="eyes", remove=true)
message(action="react", channelId="<credit_verification_channel_id>", messageId="<msg_ts>", emoji="mag")
```
Then post in-thread tagging Jan:

```
🔍 ESCALATION — [Profile Name] as [Role] on "[Track Title]" ([Artists])
Profile-ID: [profile_id]

Evidence: [1-2 sentence summary of investigation findings, grounded only in what was actually loaded — see session_evidence below]

session_evidence
```json
<paste $SESSION_EVIDENCE verbatim>
```

Sources (Tier 1 — ONLY URLs from session_evidence.browser_loads[]):
• [host from browser_loads[].host]: <url from browser_loads[].url> — [what was found, or "loaded but no data"]
(omit this list entirely if session_evidence.count_ok == 0; say "No Tier 1 sources were successfully loaded in this session." instead)

Risk score: [X]% | Verdict: Unverifiable — Needs Review
<@U038BM16T7W> — please review. Reply "approve" or "reject [reason]" in this thread.
```

**Profile-ID line is required (PR #233 follow-up).** The literal string `Profile-ID: <uuid>` must appear in the escalation body. The `block-escalation-without-browse` plugin hook extracts the UUID via regex and enforces a per-profile floor: at least 2 distinct successful browser loads in the run window must reference this specific profile (either via the muso.ai/profile/<uuid> internal page OR a Tier-1 URL whose query/path contains the UUID). The session-wide ≥2-Tier-1 floor still applies as a fallback when the Profile-ID line is missing — but escalations without the line will be visibly older-style and easier to audit. The new per-profile floor closes the "investigate one profile, escalate the rest with boilerplate" pattern observed in the 2026-05-01 09:33 UTC dry-run (10 escalations, only 1 profile actually browsed).

**Thread interaction:** Jan (or Aaron) can interact naturally in the thread:

- **"approve"** or **"approved"** → approve the credit request
- **"reject [reason]"** or **"rejected [reason]"** → reject with the given reason
- **Any other message** (questions, comments, discussion) → respond conversationally,
  answer questions about the investigation, provide more detail if asked. Use your
  existing skills (admin API lookups, Athena queries, web research) to help Jan make
  her decision. Stay in the thread.

**Sender verification:** Only Jan Delmo (`U038BM16T7W`) or Aaron (`U7RP6HKUZ`) can
trigger approve/reject actions. Verify `sender_id` from message metadata. Other users
can chat in the thread but their messages never trigger status changes.

**Executing a decision:** When Jan or Aaron says "approve" or "reject":
1. Call the admin API with their Slack ID as `--requester`:
   - Approve: `PUT /admin/credit-requests` with `{"requestIds":["<id>"],"status":"approved"}`
   - Reject: `PUT /admin/credit-requests` with `{"requestIds":["<id>"],"status":"rejected","reason":"[reason from Jan]"}`
   **Important:** Use the bulk status endpoint (`PUT /admin/credit-requests`), NOT
   the per-request endpoint (`PUT /admin/credit-requests/:id`) which only updates credits.
2. The credit can be in any status (`unverified`, `user_verification_needed`, or
   even `rejected` for borderline overrides) — execute the decision regardless.
   If the API returns an error, post it in-thread and let Jan know it needs to be
   done manually via admin panel.
3. Update the emoji on the parent message. YOU MUST call:
   ```
   message(action="react", channelId="<credit_verification_channel_id>", messageId="<parent_msg_ts>", emoji="mag", remove=true)
   message(action="react", channelId="<credit_verification_channel_id>", messageId="<parent_msg_ts>", emoji="white_check_mark")
   ```
   (Use `emoji="x"` instead of `white_check_mark` if the decision is "reject")
4. Post confirmation in-thread

#### API Failure

If the admin API call to approve/reject fails, post error in-thread:
```
⚠️ API ERROR — Failed to [approve/reject] credit request [ID].

Error: [error details]

Manual action required.
```

Do NOT retry automatically.

### Step 6: Report

Post investigation summary in-thread on the original message.

**Auto-approve format:**
```
✅ APPROVED — [Profile Name] as [Role] on "[Track Title]" ([Artists])

Evidence: [1-2 sentence summary of why this is legit]

Sources (Tier 1):
• Apple Music credits: <url> — [what was found, or "no credits listed"]
• MusicBrainz: <url> — [what was found, or "no results"]
• Discogs: <url> — [what was found, or "no results"]
• AllMusic: <url> — [what was found, or "no results"]
[Tier 2 — if writing/publishing role was checked:]
• ASCAP/BMI/SESAC: <url> — [what was found]
[Tier 3 — if checked:]
• [source]: <url> — [what was found]

Risk score: [X]% | Verdict: [Verdict]
Note: [1 sentence on why risk flag is a false positive, if applicable]
Credit request [ID] approved.
```

**Manual reject format (escalation thread only — used when Jan/Aaron issue a `reject` command):**
```
🔴 REJECTED — [Profile Name] as [Role] on "[Track Title]" ([Artists])

Evidence: [1-2 sentence summary of fraud signals]

Sources (Tier 1):
• Apple Music credits: <url> — [what was found, or "no credits listed"]
• MusicBrainz: <url> — [what was found, or "no results"]
• Discogs: <url> — [what was found, or "no results"]
• AllMusic: <url> — [what was found, or "no results"]
[Tier 2/3 sources checked, if any]

Risk score: [X]% | Verdict: [Verdict]
Credit request [ID] rejected. Reason: [reason]
```

## Relationship to Other Verification Workflows

Three verification workflows exist, each serving a different purpose:

- **Reactive verification (this skill, Steps 0-6):** Pre-approval review of
  flagged credits (risk >= 85%) posted by core-backend to #credit-verification.
  Processes one credit per message, immediately.

- **Batch verification (this skill, Batch Mode):** Proactive queue processing
  via cron (`credit-verification-batch-4h`, `0 */4 * * *` UTC). Fetches up to
  `$FETCH_SIZE` (currently 500) unverified credits every 4 hours and processes
  them, posting a summary with a Jan-tagged thread.
  Catches credits that reactive mode doesn't see (risk < 85%). Idempotency check
  prevents double-processing with reactive. Approvals are capped at 500/day UTC;
  verification-needed moves are uncapped.

- **Daily fraud scan (HEARTBEAT.md):** Post-approval review of already-approved
  credits on high-popularity tracks (Spotify pop >= 50). Different population —
  only looks at credits that have already been approved.

All three should continue running. They complement each other.

---

## Batch Mode (Cron Task)

Proactive queue processing triggered by cron (`credit-verification-batch-4h`,
`0 */4 * * *` UTC — 6 runs/day). Instead of reacting to a channel message, the
agent fetches unverified credits from the API and processes them in a batch.

### When This Applies

This mode applies ONLY when executing the `credit-verification-batch-4h` cron or
the on-demand Slack `run credit verification batch` trigger. It does NOT apply
when responding to messages in #credit-verification — those use the reactive
workflow above (Steps 0-6).

### Batch Workflow

#### B0. Setup — lockfile, run_id, fetch_size

Before any network work, initialize the run context.

**HARD RULE — run the batch inline, never in a subagent.** B0–B6 execute in this turn, in the main agent's context. Do NOT use the `agent()` / subagent-spawn tool for batch processing. Three concrete failure modes from 2026-04-23 14:20 UTC:

1. Subagent inherits `OPS_RUN_ID` from parent but calls `runlog.sh init` anyway → two run_ids for one intent → two `.results.jsonl` files → split reconciliation → `compute-run-summary.sh` sees only half the truth.
2. Subagent hits its own token limit mid-batch and times out with partial work done → main agent has no way to reconcile what actually happened → improvised Slack summary.
3. Main agent's curiosity during the wait (reading, browsing to "check on progress") leaks tool calls into the same session directory the gate scans → cross-contamination.

`runlog.sh init` refuses to run when `OPS_RUN_ID` is already set (R4-2 mechanical counterpart); if you see exit code 4, you are in a subagent context — exit the batch, let the parent run it.

If the token window is too small: lower `OPS_BATCH_FETCH_SIZE` (env var, default tuned for the current model).

**Sizing the cron window (post-PR-#236).** The per-profile subagent investigation pool is the throughput bottleneck, not the API or token window. `fetch-queue.sh` enforces a hard cap of 200 credits per run (`OPS_BATCH_FETCH_HARD_CAP`); requests above that are silently capped and a warning is logged. Math:

- 30-min cron window × 10-slot subagent pool × ~30s per HTTP-only investigation = ~600 profile-slots theoretical
- Realistic: ~50 profile groups (≈200 credits at 4 credits/profile) accounting for retry, timeout, partial failure, network variance

To drain the 12k+ unverified queue faster, run **more cron windows** (every 4h) — not larger batches. Larger batches that exceed pool throughput just panic-finalize via the runlog gate (exit 7 `acted_without_investigation`) and produce zero progress with truth-floor noise.

`OPS_BATCH_FETCH_HARD_CAP` can be raised for one-off backfill runs supervised by a human, but never as a default.

**0a. Verify required env.** Fail loudly if any of these are missing:
- `OPS_BATCH_LOCK_PATH` — absolute path to lockfile (e.g. `/root/.openclaw/locks/ops-credit-batch.lock`)
- `OPS_AUDIT_LOG_DIR` — audit log base (e.g. `/root/.openclaw/api-logs/admin`)
- `OPS_RUNLOG_DIR` — run-log base (e.g. `/root/.openclaw/api-logs/credit-batch-runs`)
- `OPS_WORKSPACE` — either `operations-dev` or `operations`
- `OPS_BATCH_ENABLED` — must be `true` (default). Set to `false` to suppress batches on the twin not currently running.
- If `OPS_DRY_RUN=1`: also require `OPS_CREDIT_VERIFICATION_DRY_RUN_CHANNEL_ID`. Abort at B0a if unset — we never silently post dry-run output to the prod channel.

If `OPS_BATCH_ENABLED != "true"`, exit silently with no Slack post.

**0b. Acquire lockfile.**

The lockfile uses PID liveness as the primary signal and a **3h30m** mtime fallback for cases where a process was killed without releasing (SIGKILL, host crash). 3h30m sits inside the 4h cron cadence — a SIGKILL-stuck lock is self-stolen by the very next tick with 30min of slack. In practice the batch never exceeds ~30min; if you see runs approaching 3h30m you have a deeper problem to investigate.

```bash
SKILL_DIR=/opt/hydra/workspaces/operations/skills/muso-ops-credit-verification
# Pass our own $$ so the lockfile records the long-lived caller PID, not the
# helper script's ephemeral PID (which dies on return).
bash "$SKILL_DIR/scripts/lockfile.sh" acquire $$
case $? in
  0) ;;       # acquired
  10) exit 0 ;;  # another run holds it, exit silently
  *) echo "Lockfile error"; exit 1 ;;
esac
trap 'bash "$SKILL_DIR/scripts/lockfile.sh" release' EXIT
```

**Multi-exec note (added 2026-04-28).** The trap above releases the lock WITHOUT `--final` — it does NOT autofill `run_finished` via `compute-run-summary.sh`. Mid-batch exec calls (e.g. agent splits B0+B1 and B2+ across two execs) can therefore fire the trap safely without polluting the runlog with a premature hollow event.

The TERMINAL release at the end of B6 must opt-in by passing `--final` (or `OPS_BATCH_TERMINAL=1`). The B6 wrap-up (see below) does this explicitly via `compute-run-summary.sh --final`. Do NOT add `--final` to the B0b trap above — that would re-introduce the 2026-04-28 15:35 UTC `run_finished_hollow` race.

**0c. Init run log and read phase variables.**
```bash
RUN_ID=$(bash "$SKILL_DIR/scripts/runlog.sh" init)
# Export OPS_RUN_ID so every downstream muso-admin-api.sh invocation
# (which reads this env) stamps its audit line with the run_id, making
# post-mortem correlation between runlog and audit JSONL trivial.
# Critical in dry-run mode — without this, every audit line has run_id:null.
export OPS_RUN_ID="$RUN_ID"
FETCH_SIZE="${OPS_BATCH_FETCH_SIZE:-10}"   # ← phase knob; set OPS_BATCH_FETCH_SIZE env to ramp 10→25→50→100
APPROVAL_CAP_LIMIT=500

# CRITICAL: count-approvals.sh must succeed AND return a number. If it returns
# empty (script errored, captured as ""), `[[ "" -ge 500 ]]` evaluates false
# and the cap is silently disabled. Assert numeric explicitly.
APPROVAL_CAP_USED=$(bash "$SKILL_DIR/scripts/count-approvals.sh") || {
  echo "FATAL: count-approvals.sh failed (exit $?); aborting batch to avoid uncapped approvals" >&2
  exit 1
}
if ! [[ "$APPROVAL_CAP_USED" =~ ^[0-9]+$ ]]; then
  echo "FATAL: count-approvals.sh returned non-numeric output: '$APPROVAL_CAP_USED'; aborting batch" >&2
  exit 1
fi

bash "$SKILL_DIR/scripts/runlog.sh" event "$RUN_ID" run_started \
  "$(jq -n --arg phase "${OPS_BATCH_PHASE:-0}" --argjson fs "$FETCH_SIZE" \
          --argjson cu "$APPROVAL_CAP_USED" --argjson cl "$APPROVAL_CAP_LIMIT" \
          '{phase:$phase, fetch_size:$fs, approval_cap_used_at_start:$cu, approval_cap_limit:$cl}')"
```

**0c.5. Browser tab hygiene — close stale tabs.**

Run 20260504-215412-2067ce hit a degraded browser state: 17 stale tabs (captcha challenge pages, service workers, blob: URLs from prior runs) had piled up in the headless Chrome process. Browser snapshots for fresh Tier-1 loads came back empty (`Source: Browser\n---\n` wrapper, ~769 bytes, no content) for discogs / musicbrainz / google / tidal — even though those URLs work fine from a clean browser. The agent correctly declined to fabricate verdicts and the run finished hollow, but the run wasted the cron window on an environment problem.

Close all tabs and reopen a single fresh `about:blank` BEFORE the pre-flight probe so the probe (and B3 browsing) starts from clean state. The helper does this via the `openclaw browser` CLI directly — the agent's `browser` tool can't enumerate-and-close tabs reliably from inside the same session.

```bash
bash "$SKILL_DIR/scripts/cleanup-browser-tabs.sh" 2>&1 | tail -1
# Logs a single JSON line: {"closed": <int>, "remaining": <int>}
# remaining should always be 1 (the fresh about:blank).
```

This step is best-effort — a non-zero exit (e.g. CLI not on PATH) doesn't abort the batch; B0d (the pre-flight probe below) will fail loudly anyway if the browser is unusable.

**0d. Browser tool pre-flight probe.**

Cron-invoked isolated sessions have silently lost `browser` tool availability in the past (2026-04-16 20:39 UTC run produced 332 escalations that cited Tier 1 URLs the agent never loaded; 2026-04-20 13:26 UTC b8b0e5 approved with `web_fetch` substituted for the probe). Before touching any credit API, verify the tool actually works in *this* session. If it doesn't, abort loudly at B0 so no confabulated escalations land downstream.

The probe URL is:

```
https://musicbrainz.org/artist/072e9356-1cf1-4096-b9f1-3878a9e4961d
```

(Drake — a consistently available Tier 1 artist page with a predictable HTML shape.)

Success criteria: the tool result must be non-error AND the returned text must contain both of these literal substrings (case-insensitive): `musicbrainz` and `drake`. Cloudflare challenge pages and empty responses fail.

**Do NOT call the `browser` tool yourself.** The 2026-04-28 14:24/14:28/14:51 UTC dry-runs all failed because the openai/gpt-5.5 model's tool-schema defaults (`mode: "efficient", depth: 0, snapshotFormat: "ai", compact: true`) produced a 0-char snapshot that fails the markers check. SKILL.md instructions to "use these exact args instead" did not override the schema defaults — the model kept emitting them. The mechanical layer is the only fix: `preflight-verify.sh` runs the probe via `openclaw browser` CLI directly, with correct args, bypassing the agent's tool-call construction entirely.

After the probe attempt, call the verify helper. **You MUST NOT write the `preflight_ok` or `preflight_browser_unavailable` event with `runlog.sh` directly** — the helper does it, derived from the session JSONL the harness recorded. Hand-writing these events is the failure class this step exists to close.

```bash
set +e
bash "$SKILL_DIR/scripts/preflight-verify.sh" "$RUN_ID"
PREFLIGHT_STATUS=$?
set -e
```

| Exit code | Meaning | Required action |
|---|---|---|
| `0` | Probe confirmed in session JSONL. Event `preflight_ok` is already written. | Fall through to B1. |
| `10` | No successful browser load of the probe URL with the required markers. Event `preflight_browser_unavailable` is already written. | Post the Slack abort message (below), exit the turn. |
| `2` or `3` or other non-zero | Helper env/config/session-log error. No event written. | Post the Slack abort message with the exit code, exit the turn. Do NOT proceed — an indeterminate pre-flight is not a green light. |

**If the helper reports failure (any non-zero exit), post a single short message to `#credit-verification` (no thread). Use the template that matches the exit code so the cause is visible at a glance:**

- `10` (browser load not confirmed):
  ```
  ⚠️ Batch aborted at pre-flight — browser tool unavailable in this session. Run ID: <RUN_ID>. No credits processed.
  ```
- `2` / `3` / any other non-zero (helper env / session-log / config error):
  ```
  ⚠️ Batch aborted at pre-flight — helper exit <PREFLIGHT_STATUS>. Run ID: <RUN_ID>. No credits processed.
  ```

Exit the turn. Do NOT proceed to B1. The `trap … EXIT` set in B0b releases the lockfile automatically; no further cleanup needed.

**HARD RULE — no manual-override phase.** Once `preflight_browser_unavailable` is logged for a run, the turn exits. There is no "phase=manual" path, no "proceeding with caution" path, no way to continue in the same run. The mechanical counterpart: `runlog.sh` refuses every subsequent `event` call on that run with exit 20 (2026-04-20 13:19 UTC 2bfea8 is the incident this closes). If you need to retry, start a fresh run with a new lockfile + run_id.

#### B0d.5. Session Hygiene (contamination check)

openclaw channel-keys sessions: the same `.jsonl` file persists across runs and gateway restarts in the Slack `#credit-verification` thread. If an earlier run made a `web_fetch` to a Tier-1 host (Apple / MusicBrainz / Discogs / AllMusic), those lines remain in the file and can still contaminate this run unless scoped.

The gate (R3-3) already filters its scan by `run_started.ts`, so past contamination can't block today's approves. But fail-fast is still worth it — aborting here is cheaper than letting B2 spend minutes processing before every approve rejects with the same reason.

```bash
bash "$SKILL_DIR/scripts/session-evidence.sh" --check-tier1-webfetch
```

- Exit `0`: session is clean OR past web_fetch was written before this run's `run_started` (automatically excluded). Fall through to B1.
- Exit `1`: Tier-1 `web_fetch` detected WITHIN the current run window. Post this short abort message to `#credit-verification` (no thread), then exit the turn:

  ```
  ⚠️ Batch aborted at B0d.5 — Tier-1 web_fetch detected in this run's session.
  Run ID: <RUN_ID>. Host(s): <from stderr bullet list>.
  The enforcer plugin's block-web-fetch-tier1 hook did not fire — escalating to Jan. <@U038BM16T7W>
  ```

  Do NOT retry within the same run — the session is tainted. The next scheduled cron tick (or a fresh `@Ops (dry-run)` post that starts a new topic-keyed session) is the recovery path.

This check is belt-and-braces: the gate in R3-3 also scopes its scan, so even if B0d.5 were skipped the approves would still refuse. Running it explicitly turns a "gate rejects every approve, takes 30min to discover" failure into a "batch aborts in 2 seconds with a named host" failure.

#### B1. Fetch the Queue

**HARD RULE — single entry point.** The queue is fetched ONLY through `fetch-queue.sh`. Do NOT invoke `muso-admin-api.sh` directly for `/admin/credit-requests` or `/admin/credit-requests/counts` from B1, and do NOT improvise jq parsing of admin-API responses. The 2026-04-27 10:06 UTC dry-run posted a green "Queue clear" while the live API had 13891 unverified credits queued — root cause was agent-improvised `.body.items // .items // [] | length` falling silently through to `0` because the real envelope is `.body.data.items[]`. The script locks the jq paths, asserts HTTP status, and fails LOUD on the silent-zero pattern.

```bash
set +e
QUEUE_JSON=$(bash "$SKILL_DIR/scripts/fetch-queue.sh" "$FETCH_SIZE")
RC=$?
set -e
```

The script's stdout (on RC=0) is a single JSON object: `{"queue_depth": <int>, "items": [...], "fetch_size": <int>}`. **Do not re-parse `.body.data.items` anywhere downstream — the script has already unwrapped it.** B2 reads `$QUEUE_JSON | .items` directly.

Dispatch on `$RC`:

| RC | Meaning | Required action |
|----|---------|-----------------|
| `0` | Success — `$QUEUE_JSON` is the normalized envelope. | **Proceed directly to B2 (per-profile processing).** If `.queue_depth == 0` AND `.items\|length == 0` this is a genuine queue-clear; route through B5. **HARD RULE — do NOT post any Slack summary at this point.** A non-empty queue means the run continues through B2 → B3, where B3 composes the single batch summary post. The 2026-04-28 15:13 UTC dry-run failed this rule: agent posted "Queue fetch succeeded — no writes were executed" after B1 and stopped, producing a `run_finished_hollow` event because `fetched=500` but `approved+verification_needed=0`. Dry-run does NOT short-circuit the workflow — it intercepts API writes via the wrapper, but B2-B5 still run end-to-end so the gate, classification, and summary code all get exercised. |
| `2` | Wrapper missing or non-numeric `fetch_size`. | Post API-error status (template below), stop. |
| `3` or `4` | List or counts endpoint returned non-200. | Post API-error status (template below), stop. Stderr from the script has the wrapper response body. |
| `5` or `6` | **Envelope shape drift.** List response missing `.body.data.items` (5) or counts response missing `.body.data[0].count` (6). The admin API schema has changed under us. | Do NOT post queue-clear. Post the shape-drift escalation template (below) tagging Jan, then stop. |
| `11` | **`unverified_count_items_mismatch`** — counts say there are unverified credits but the list returned zero items. The exact silent-zero pattern this script exists to catch. | Do NOT post queue-clear. Post the shape-drift escalation template tagging Jan, then stop. |

Record queue depth to the run log on RC=0:
```bash
TOTAL_UNVERIFIED=$(echo "$QUEUE_JSON" | jq -r '.queue_depth')
bash "$SKILL_DIR/scripts/runlog.sh" event "$RUN_ID" run_started_queue \
  "$(jq -n --argjson depth "$TOTAL_UNVERIFIED" '{queue_depth_at_start:$depth}')"
```

**B1.5 — Post the in-thread "starting" announcement (REQUIRED).** Immediately after the queue is fetched and before B2 begins per-profile work, post a brief reply in the parent thread so the user sees activity right away. This is mechanical, not optional — `browser-evidence-audit.sh` refuses the final summary post if the runlog has any `profile_group_fetched` events but no `batch_announced` event.

```bash
# QUEUE_JSON is already in scope from the fetch-queue.sh call above. Persist
# it to the canonical path so post-batch-announce.sh can group items by profile.
echo "$QUEUE_JSON" > "/tmp/${RUN_ID}.queue.json"

# Pass the parent thread ts as arg 2 (the same value used by compute-run-summary.sh
# below in B3). Cron runs set it explicitly; reactive runs inherit from the
# inbound thread. The script also reads OPS_PARENT_MSG_TS as a fallback.
bash "$SKILL_DIR/scripts/post-batch-announce.sh" "$RUN_ID" "$PARENT_MSG_TS"
```

The script posts via the openclaw CLI with `--reply-to "$OPS_PARENT_MSG_TS"` (so it lands in the same thread, not as a top-level channel message), writes a `batch_announced` runlog event, and is idempotent on repeated invocation. If the openclaw CLI emits "Config warnings:" prelude before the JSON response, the script tolerates it and writes a `script_warning` event for forensics.

The list endpoint returns `createdAt DESC` by default (newest first = LIFO).

- **If `.queue_depth == 0` and `.items|length == 0`:** Post the queue-clear message (see B5) and stop. This is exit 0 from `fetch-queue.sh` — never inferred from missing fields.
- **If RC ∈ {2, 3, 4}:** Post the API-error status to `#credit-verification` and stop:
  ```
  [HEARTBEAT-BATCH] Credit Verification Batch — [timestamp]
  ⚠️ API error fetching unverified queue. Skipping this cycle.
  Error: [stderr from fetch-queue.sh]
  ```
- **If RC ∈ {5, 6, 11}:** Post the shape-drift / silent-zero escalation to `#credit-verification` (no thread, prepend `<dry_run_prefix>`) and stop. Tag Jan ONLY in production (skip the `@`-tag in dry-run per the `OPS_DRY_RUN=1` rules above):
  ```
  [HEARTBEAT-BATCH] Credit Verification Batch — [timestamp]
  ⚠️ Batch aborted at B1 — admin API envelope drift OR silent-zero (count>0, items=0).
  fetch-queue.sh exit: <RC>
  Error: [stderr from fetch-queue.sh]
  Escalating: <@U038BM16T7W>
  ```

#### B2. Process Each Profile

**Structural change (R3, 2026-04-23):** iteration unit is now the **profile**, not the individual credit. The gate's evidence quorum is per-profile — loading 2 artist-level pages for the whole batch doesn't satisfy it for 30 distinct profiles. Group the fetched queue by `profile_id` first, then for each group do: gather Tier-1 evidence → classify → act via `batch-verify-profile.sh`.

Initialize in-run counters:
```bash
MOVES_COUNT=0           # total UVN moves across profiles — runaway rail
APPROVED_IN_RUN=0       # total credits approved across profiles
ERRORS=0                # total delegate/HTTP errors
```

Group the fetched queue by `profile_id`:
```bash
# $QUEUE_JSON is the normalized envelope from B1's fetch-queue.sh:
# {"queue_depth": <int>, "items": [...], "fetch_size": <int>}.
# `.items` is already unwrapped — DO NOT add `.body.items` / `.body.data.items`
# fallbacks here. The 2026-04-27 silent-zero incident is exactly the failure
# mode of guessing admin-API envelope shapes from inside SKILL.md.
# Produce: profiles_ordered[] = array of {profile_id, userid, cr_ids:[...]}
# NOTE: jq's group_by requires sorted input to coalesce same-profile items
# into a single group. The admin API may return items in createdAt DESC
# order, which interleaves multiple profiles — without sort_by first, the
# same profile appears as multiple groups, causing duplicate batch calls.
PROFILES_GROUPED=$(echo "$QUEUE_JSON" | jq -c '
    # Preserve external IDs per credit so build-search-url.sh can use direct
    # entity URLs instead of fragile search URLs (PR #236 Phase 2).
    # Field names verified against live admin API 2026-05-01:
    #   .trackId             - muso internal track UUID
    #   .spotifyTrackId      - Spotify track ID (NOT .spotifyId — that lives on .profile)
    #   .spotifyTrackTitle   - track title as Spotify reports it (often cleaner)
    #   .spotifyTrackArtists - [{id, name}] with Spotify artist IDs
    #   .metadata.isrc       - ISRC string (nested, not top-level)
    #   .credits             - ARRAY OF ROLE NAME STRINGS for this credit-request
    #                          (e.g. ["Mixing", "Mastering"]) — not nested objects
    # API does NOT (today) return: appleMusicId, musicbrainzId, tidalId,
    # discogsId. Build-search-url.sh accepts those flags for future use; for
    # now those env vars are emitted empty and the helper falls back to
    # encoded search URLs for those hosts.
    def credit_ids: {
      cr_id:               .id,
      track_id:            (.trackId // null),
      spotify_track_id:    (.spotifyTrackId // null),
      spotify_track_title: (.spotifyTrackTitle // null),
      spotify_artist_ids:  ((.spotifyTrackArtists // []) | map(.id) | map(select(. != null))),
      isrc:                (.metadata.isrc // null),
      label:               (.metadata.label // null),
      roles:               (.credits // []),
      popularity:          (.spotifyPopularity // null),
      risk_total:          (.verificationData.total_risk_percent // null)
    };
    .items
    | sort_by(.profileId // .profile_id)
    | group_by(.profileId // .profile_id)
    | map({
        profile_id: (.[0].profileId // .[0].profile_id),
        userid: (.[0].userId // .[0].user_id),
        # Profile-level signals used by the risk-steering table in Step 3
        profile_credit_count: (.[0].profile.creditCount // null),
        profile_popularity:   (.[0].profile.popularity // null),
        profile_spotify_id:   (.[0].profile.spotifyId // null),
        profile_name:         (.[0].profile.name // null),
        cr_ids: [.[] | .id],
        credits: [.[] | credit_ids]
      })
')
```

For each profile group:

1. **Log the group.** Include `credited_name`, `track_title`, `role` so the dispatcher (B3a) and runlog gate (PR #235) can resolve them per profile. Also include the `credits[]` array (with per-credit external IDs from B2's grouping) so the dispatcher can pass `--spotify-id`/`--isrc`/etc. to `build-search-url.sh` and use direct entity URLs.
   ```bash
   # $CREDITS_JSON is the .credits array from this profile's group in
   # PROFILES_GROUPED — it carries one object per cr_id with track_id,
   # spotify_id, isrc, apple_music_id, musicbrainz_id, tidal_id, discogs_id
   # (any of which may be null if the API didn't return them).
   bash "$SKILL_DIR/scripts/runlog.sh" event "$RUN_ID" profile_group_fetched \
     "$(jq -n --arg pid "$PROFILE_ID" --arg uid "$USER_ID" \
            --arg cn "$CREDITED_NAME" --arg tt "$TRACK_TITLE" --arg rl "$ROLE" \
            --argjson ids "$CR_IDS_JSON" --argjson credits "$CREDITS_JSON" \
            '{profile_id:$pid, userid:$uid, cr_ids:$ids, count:($ids|length),
              credited_name:$cn, track_title:$tt, role:$rl, credits:$credits}')"
   ```

2. **Idempotency filter.** Within the group, drop any `cr_id` whose `current_status` is not `unverified` or `user_verification_needed`. For each dropped id, log `skip_idempotent`. If the group is empty after filtering, continue to the next profile.

3. **Gather per-profile Tier-1 evidence — MANDATORY before step 4.**

---

### B3. Per-profile inline browser investigation — the only path TODAY

Per-profile evidence collection runs **inline in the parent agent** using the `browser` tool. The parent has a working browser node binding; subagents do not (their `browser.open()` calls time out with "No connected browser-capable nodes" — see `templates/investigate-profile.md` for the deferred-work note). When subagent browser access is wired in a future PR, this section will switch to a fan-out pool. Until then: serial inline.

**🚫 NEVER use `web_fetch` for Tier-1 hosts.** Apple Music / MusicBrainz / Discogs / AllMusic / Tidal are JS-rendered SPAs. `web_fetch` returns the empty HTML shell with no credit data. The plugin hook `block-web-fetch-tier1` will refuse the call; the bash gate in `muso-admin-api.sh` will refuse any approve where Tier-1 web_fetch was used. Use `browser` only. (See `feedback_browser_only_for_tier1.md`.)

**🚫 Spotify is NOT Tier-1** (dropped 2026-05-05). The Spotify credits dialog is login-gated for unauthenticated headless browsers — even with the More options → View credits click sequence the dialog rows are `-` for many tracks, and even when populated the values are hidden for guests. Do NOT load `open.spotify.com/track/<id>` in the browser to count toward Tier-1 quorum — neither the canonical regex (`lib/browser-evidence.sh:67`) nor the bash gate (`muso-admin-api.sh` `CV_TIER1_HOSTS`) accept `open.spotify.com` anymore. The `spotifyTrackId` field on a credit-request item is used internally for muso UUID resolution only.

**Why no batch-level shortcut:** runs `20260501-100843-d27818`, `20260501-122847-b476d5`, and `20260501-135646-ecff37` all proved the inline-loop main agent converges on heuristic shortcuts under time pressure. The defense is no longer "fresh-context subagents" — it's the **mechanical gates**, which now hold:

- `runlog.sh` exit 7 `acted_without_investigation` refuses any `action_attempted` event whose `profile_id` lacks a successful per-profile browser load
- `runlog.sh` exit 7 `verdict_without_evidence` refuses any `verdict` / `escalation_posted` event likewise
- `batch-verify-profile.sh` exit 5 `missing_profile_browse` refuses any PUT-write
- The plugin `block-escalation-without-browse` refuses Slack escalation posts likewise
- The plugin `block-web-fetch-tier1` refuses Tier-1 web_fetch attempts (the obvious workaround)

The agent CAN'T cheat without one of these firing. If subagents can't ground a verdict, the safe behavior is **exit early with `run_finished_browse_unavailable`** — cron retries next window. Do NOT bulk-fire `action_attempted` to "let the gate decide" — the runlog gate refuses those too.

**Workflow (after B0-B2 complete + ALL `profile_group_fetched` events logged):**

For each profile group from B2, the parent agent runs the following loop. Profile groups are processed serially — performance budget is ~20s per profile (anchor load + 2 Tier-1 loads + verdict logging), ~17 min for 50 profiles in a 30-min cron window.

```bash
# Pseudocode — actual tool calls are browser.open / browser.snapshot from the agent
for profile in profiles_grouped:
  PROFILE_ID = profile.profile_id
  CREDITED_NAME = profile.credited_name
  TRACK_TITLE   = profile.track_title
  ROLE          = profile.role
  CR_IDS        = profile.cr_ids
  CREDITS_JSON  = profile.credits  # has spotify_track_id, isrc, spotify_artist_ids[], etc.

  # 1. TIER-1 VERIFICATION — at least 2 distinct hosts.
  #    The runlog gate counts a "successful per-profile browse" as a Tier-1
  #    browser.open whose response text contains CREDITED_NAME AND either
  #    TRACK_TITLE or one of the role tokens. The muso website anchor was
  #    dropped 2026-05-04 — per-profile evidence now comes purely from
  #    Tier-1 pages.
  #
  #    TIER-1 HOSTS (4, mechanically enforced by lib/browser-evidence.sh:67
  #    and plugins/muso-credit-verification-enforcer/.../block-*.ts):
  #      (open.spotify.com was Tier-1 until 2026-05-05; dropped because the
  #       credits dialog is login-gated for headless. Load the corresponding
  #       MusicBrainz / Apple Music page instead.)
  #                            `browser` not `web_fetch`; the login wall on
  #                            individual track pages is fine — credits live
  #                            on the artist/album view).
  #      - music.apple.com   — credit panel (Performing Artists / Composition &
  #                            Lyrics / Production & Engineering). Use the US
  #                            storefront uniformly: music.apple.com/us/song/...
  #                            (rewrite kg/gb/jp/... → us; Apple serves the
  #                            same track from the US catalog for any track
  #                            it has, pinning the storefront keeps URLs
  #                            canonical for audit and excerpt-quorum dedup).
  #      - musicbrainz.org   — recording-level credits, open
  #      - discogs.com       — release-level credits (writers, producers,
  #                            mixing/mastering, instruments per performer)
  #      - allmusic.com      — album credits panel
  #
  #    SUPPORTING (Tier-2, does NOT count toward the Tier-1 quorum):
  #      - tidal.com         — /album/<id>/credits useful corroboration; the
  #                            backend `/admin/album/<id>/sources` endpoint
  #                            still returns these IDs to seed the search
  #                            URL builder, but the gate counts only the 5
  #                            hosts above.
  #
  #    THREE-BRANCH DECISION on cr.tier1_sources.backend_tier1_count
  #    (populated by fetch-queue.sh from /admin/track/<id>/sources +
  #     /admin/album/<id>/sources — today only Tidal is in the muso catalog;
  #     Apple/MB/Discogs/AllMusic IDs land via hydra issue #236):
  #
  #     >= 2 backend hits → open the backend Tier-1 URLs only, snapshot,
  #                         claim-match. Skip the search-and-click chain
  #                         entirely. (Rare today; common after #236.)
  #
  #     == 1 backend hit  → open the backend Tier-1 URL FIRST, then run
  #                         search-and-click for ONE more host (priority:
  #                         music.apple.com). Stop once 2 hosts confirm
  #                         OR after attempting 2 search-and-clicks.
  #                         (Typical today: backend has Tidal album from
  #                         /admin/album/<id>/sources.)
  #
  #     == 0 backend hits → full search-and-click chain in priority order:
  #                         musicbrainz → apple → discogs → allmusic →
  #                         tidal-search. Stop once 2 hosts confirm.
  #                         (Common for fresh / indie tracks not yet in
  #                         the muso catalog, or tracks where trackId is
  #                         null at fetch time.)
  #
  #    URL building: use scripts/build-search-url.sh. For backend Tidal,
  #    pass --tidal-album-id "$TIER1.tidal_album_id" — the helper emits
  #    https://tidal.com/album/<id>/credits which is the credits-panel
  #    page (verified live 2026-05-04). For all other hosts, pass any
  #    available external IDs (--spotify-id used internally for catalog
  #    lookups, --isrc, --musicbrainz-id, --apple-music-id, --discogs-id);
  #    the helper falls back to canonical search URLs when no ID is set.

  TIER1=$(jq -c '.tier1_sources // {backend_tier1_count:0}' <<<"$cr")
  BACKEND_COUNT=$(jq -r '.backend_tier1_count // 0' <<<"$TIER1")
  TIDAL_ALBUM_ID=$(jq -r '.tidal_album_id // empty' <<<"$TIER1")

  CONFIRMED_HOSTS=()  # 2-element ceiling — once it hits 2, stop loading

  # Helper: open one URL, snapshot, claim-match against credited_name and
  # (track_title | role). On match, append the host to CONFIRMED_HOSTS.
  # The exact match logic the gate uses is in lib/browser-evidence.sh; we
  # just need the snapshot text to contain CREDITED_NAME plus (TRACK_TITLE
  # OR a role token).

  # Branch A: backend ≥ 2 — open backend URLs only, no searches.
  if (( BACKEND_COUNT >= 2 )); then
    for backend_url in <each tier1_sources.*_url that is non-null>:
      browser.open("$backend_url"); snapshot = browser.snapshot()
      if claim_matches(snapshot, CREDITED_NAME, TRACK_TITLE, ROLE):
        CONFIRMED_HOSTS+=(<host>)
      [[ ${#CONFIRMED_HOSTS[@]} -ge 2 ]] && break

  # Branch B: backend == 1 — backend URL + 1 search-and-click (Apple first).
  elif (( BACKEND_COUNT == 1 )); then
    # Backend URL (today: tidal album-credits)
    if [[ -n "$TIDAL_ALBUM_ID" ]]; then
      URL=$(bash "$SKILL_DIR/scripts/build-search-url.sh" --host tidal \
            --credited-name "$CREDITED_NAME" --track-title "$TRACK_TITLE" \
            --tidal-album-id "$TIDAL_ALBUM_ID")
      browser.open("$URL"); snapshot = browser.snapshot()
      if claim_matches(snapshot, ...): CONFIRMED_HOSTS+=("tidal")
    fi

    # One search-and-click — Apple Music first (most reliable open credits
    # panel). If that doesn't confirm, fall through to a second host.
    for host in ["apple", "musicbrainz", "discogs", "allmusic"]:
      [[ ${#CONFIRMED_HOSTS[@]} -ge 2 ]] && break
      URL=$(bash "$SKILL_DIR/scripts/build-search-url.sh" --host $host \
            --credited-name "$CREDITED_NAME" --track-title "$TRACK_TITLE" \
            ${ISRC:+--isrc "$ISRC"})
      browser.open("$URL"); snapshot = browser.snapshot()
      # Search results page → click the right result → snapshot → claim-match.
      if claim_matches(snapshot, ...): CONFIRMED_HOSTS+=("$host")

  # Branch C: backend == 0 — full search-and-click chain.
  else
    for host in ["apple", "musicbrainz", "discogs", "allmusic", "tidal"]:
      [[ ${#CONFIRMED_HOSTS[@]} -ge 2 ]] && break
      URL=$(bash "$SKILL_DIR/scripts/build-search-url.sh" --host $host \
            --credited-name "$CREDITED_NAME" --track-title "$TRACK_TITLE" \
            ${ISRC:+--isrc "$ISRC"})
      browser.open("$URL"); snapshot = browser.snapshot()
      # Search results page → click → snapshot → claim-match.
      if claim_matches(snapshot, ...): CONFIRMED_HOSTS+=("$host")
  fi

  # Capture a verbatim ~150-char excerpt from a confirming snapshot showing
  # CREDITED_NAME near a ROLE token or TRACK_TITLE. Save for
  # batch-verify-profile.sh --evidence-excerpt. The gate uses the same
  # rule (CREDITED_NAME + role|title in the response text); once 2
  # distinct Tier-1 hosts confirm, the gate is satisfied for this profile.

  # 1b. SEARCH-ENGINE FALLBACK — last resort BEFORE invoking tier1_unreachable.
  #     If fewer than 2 Tier-1 hosts confirmed the credit, load a search-
  #     engine URL via `browser` for supplementary corroboration BEFORE
  #     giving up. This is NOT a path to APPROVE — snippet results are not
  #     authoritative enough to write the admin API on. It IS a path to
  #     downgrade what would otherwise be ESCALATE → user_verification_needed
  #     (a human will confirm). It also surfaces fraud signals the agent
  #     might otherwise miss.
  #
  #     Why browser, not web_search: the muso-credit-verification-enforcer
  #     plugin BLOCKS `web_search` in CV sessions (the gateway's DuckDuckGo
  #     backend is bot-detected and returns nothing useful — GH issue #107).
  #     Loading a search-engine URL in `browser` works around that and is
  #     the sanctioned alternative — see plugin redirect-web-search hook.
  #     Recognized search-engine hosts (the gate counts ANY of these):
  #       - https://duckduckgo.com/?q=<URL-encoded query>
  #       - https://www.bing.com/search?q=<URL-encoded query>
  #       - https://www.google.com/search?q=<URL-encoded query>
  #
  #     Examples of credible search-engine corroboration (any 1+ supports UVN):
  #       - Label/publisher site listing the credit (BMI, ASCAP, label roster)
  #       - Press release / interview where the credited person discusses
  #         the track/role
  #       - Artist's own verified site/bio mentioning the credit
  #       - Wikipedia article citing the credit with a published source
  #
  #     Examples that do NOT support UVN (too weak / adversarial):
  #       - User-generated lyrics sites (genius.com, azlyrics, etc.)
  #         unless they cite a label source
  #       - Social-media bio claims by the credited person without
  #         independent corroboration
  #       - SEO-spam aggregator pages
  if tier1_confirmed_hosts < 2:
    QUERY=urlencode("\"$CREDITED_NAME\" \"$TRACK_TITLE\" $ROLE")
    browser.open("https://duckduckgo.com/?q=$QUERY")
    snapshot = browser.snapshot()
    # Capture the strongest corroborating snippet (or note "no credible
    # corroboration found"). Save it for the verdict reason. The runlog
    # gate counts the browser load itself — the snapshot doesn't have to
    # succeed (a captcha here is itself "tier1_unreachable" evidence).

  # 2. CHOOSE VERDICT (exactly one), based on Tier-1 + search-engine results:
  #   - LEGITIMATE                    → APPROVE_IDS += CR_IDS
  #     Requires: ≥2 Tier-1 hosts confirm CREDITED_NAME + (TRACK_TITLE|ROLE)
  #   - SUSPICIOUS_CLEAR_FRAUD        → UVN_IDS += CR_IDS
  #     Requires: Tier-1 evidence shows the credit DOES NOT belong to
  #     CREDITED_NAME (e.g. MusicBrainz lists Lennon as composer, not us)
  #   - SUSPICIOUS_BORDERLINE         → UVN_IDS += CR_IDS
  #     Requires: <2 Tier-1 confirms BUT step 1b's search-engine browser
  #     load surfaced credible corroboration (label/publisher/press).
  #     Reason MUST quote the corroborating snippet + URL — gives the
  #     human reviewer a starting point.
  #   - INCONCLUSIVE_TIER1_UNREACHABLE → UVN_IDS += CR_IDS
  #     Requires: <2 Tier-1 confirms AND the search-engine browser load
  #     surfaced no credible corroboration. Reason MUST contain
  #     'tier1_unreachable' AND name each Tier-1 host tried + how each
  #     failed (rate-limit, no match, captcha, dialog empty), AND note
  #     the search-engine outcome.
  #     2026-05-05 update: this case maps to UVN (verification_needed
  #     queue) not ESCALATE. Indie-track-heavy queues legitimately produce
  #     no Tier-1 coverage; flooding Slack with one escalation thread per
  #     credit is unscalable. UVN moves the credit to the verification_
  #     needed queue where humans can review at scale via the Muso admin
  #     UI, and the runlog/audit gates still enforce that the agent
  #     actually tried (≥2 Tier-1 attempts + ≥1 search-engine browser load) before this
  #     verdict can land. ESCALATE is now reserved for the
  #     `OPS_VERIFICATION_FALLBACK_TO_ESCALATE=1` override (see step 8b
  #     below) and for hollow-run failure cases where verdicts can't be
  #     written at all.

  # 3. LOG VERDICT (per-credit). Runlog gate refuses if step 1 produced 0 Tier-1
  #    loads whose response text proves the claim (exit 7). Always include profile_id.
  for CR_ID in $CR_IDS:
    bash "$SKILL_DIR/scripts/runlog.sh" event "$RUN_ID" verdict \
      "$(jq -n --arg id "$CR_ID" --arg pid "$PROFILE_ID" --arg v "$VERDICT" --arg r "$REASON" \
             '{cr_id:$id, profile_id:$pid, verdict:$v, reason:$r, signals:[]}')"

  # 4. ACT — handled by Step B8 (action_attempted is also gated on per-profile Tier-1 evidence).
```

**`tier1_unreachable` bypass — MECHANICALLY ENFORCED preconditions (2026-05-04 round 4).** The bypass is the LAST resort, only after backend Tier-1 + at least one search-and-click + the search-engine fallback all fail. It is NOT a fall-through for "the first source didn't have it, give up."

Two preconditions are now enforced by `runlog.sh` (write-time, exit 7 `tier1_unreachable_insufficient_effort`) AND `browser-evidence-audit.sh` (read-time, status 1 with `bypass_anchored_profiles` empty for the profile):

- **(a) ≥2 distinct Tier-1 browser opens for the profile** — the URL or response text must mention the profile's `credited_name` or `track_title`. A single-host attempt (e.g. only Apple Music) followed by `tier1_unreachable` will be REFUSED at write time.
- **(b) ≥1 search-engine browser load** in the run window — a `browser` toolCall whose URL is `duckduckgo.com / bing.com / google.com` (with optional `www.`) and whose `?q=` query mentions `credited_name` or `track_title`. SKILL.md step 1b must actually fire — labeling the verdict `tier1_unreachable` without that browser load will be REFUSED. (web_search itself is plugin-blocked in CV sessions; the search-engine browser load is the sanctioned alternative.)

If either precondition is unmet, the gate refuses the verdict / action_attempted / escalation_posted event (exit 7) with a clear `tier1_unreachable_insufficient_effort` message naming both counts. There is NO test escape hatch besides `CV_DISABLE_VERDICT_GATE=1` (tests only).

In addition to the mechanical enforcement, the `reason` field MUST cite WHICH Tier-1 hosts were tried and WHAT failure each returned (the audit doesn't enforce text content but you'll get a clearer human review):

1. **If `tier1_sources.backend_tier1_count >= 1`:** loaded the backend URL(s) and observed the response text — none confirmed the credit
2. **At least one search-and-click attempt** on a non-backend Tier-1 host (priority: music.apple.com when in branch B; the full chain in branch C)
3. **Load a search-engine URL via browser (step 1b)** for the credit and recorded the outcome — either the search surfaced no credible corroboration, or what it surfaced was adversarial / too weak to count
4. The `reason` field cites WHICH Tier-1 hosts were tried and WHAT failure each returned (e.g. `tier1_unreachable: tidal album-credits showed no row for credited name; apple no song-page result; musicbrainz no recording match; search-engine returned only genius.com lyrics + 2 SEO aggregators, no credible source`)

If the search-engine load surfaced credible corroboration (a label site, a press piece, BMI/ASCAP listing) the verdict is `SUSPICIOUS_BORDERLINE` (UVN, not escalate) so a human can confirm — the credit *might* be legit, the agent just couldn't get it past the Tier-1 quorum bar alone.

If only 1 host was tried, the verdict is `SUSPICIOUS_BORDERLINE` (not `INCONCLUSIVE_TIER1_UNREACHABLE`) — the agent didn't gather enough evidence to claim unreachability. NEVER fabricate excerpts to satisfy the gate.

**Forbidden in B3:**
- Skipping per-profile browse and inventing verdicts. The runlog gate (exit 7) refuses verdict / action_attempted / escalation_posted events without per-profile browser evidence. There is no "I'll let the gate decide" workaround — the gate will refuse and the run will hang.
- Calling `web_fetch` on any Tier-1 host. The plugin hook refuses. Use `browser` only.
- Reusing a previous profile's snapshot for the current profile. Each profile needs its own Tier-1 evidence — the gate counts loads whose response text mentions THIS profile's `CREDITED_NAME` and either `TRACK_TITLE` or a role token.
- Rote-classification template excerpts like `"<track> <role>"` (run 135646 pattern). Must be a verbatim substring from the rendered snapshot.

4. **Verdict event schema (logged in B3's step-4 loop).** The verdict event written for each credit MUST have shape:
   ```bash
   bash "$SKILL_DIR/scripts/runlog.sh" event "$RUN_ID" verdict \
     "$(jq -n --arg id "$CR_ID" --arg pid "$PROFILE_ID" --arg v "$VERDICT" --arg r "$REASON" \
            --argjson sig "$SIGNALS_JSON" \
            '{cr_id:$id, profile_id:$pid, verdict:$v, reason:$r, signals:$sig}')"
   ```
   **`profile_id` is REQUIRED.** The runlog gate refuses verdict events that name a `profile_id` without ≥1 successful per-profile browser load OR successful subagent investigation in the current run window (exit 7). Verdicts that omit `profile_id` entirely are accepted but flagged as `silent_failure_detected: true` in compute-run-summary — the per-profile evidence link cannot be checked. Always include the `profile_id` you're operating on; the only exception is the global `INCONCLUSIVE_TIER1_UNREACHABLE` case where reason MUST contain `tier1_unreachable`.

5. **Partition by decision.** Bucket this profile's credits using the `VERDICT` from the subagent JSON:
   ```bash
   APPROVE_IDS=()   # only VERIFIED LEGIT (≥2 Tier-1 hosts show name + role/track)
   UVN_IDS=()       # SUSPICIOUS_CLEAR_FRAUD + SUSPICIOUS_BORDERLINE +
                    # INCONCLUSIVE_TIER1_UNREACHABLE (default mapping —
                    # 2026-05-05). Indie credits with no Tier-1 coverage go
                    # to the verification_needed queue for human review at
                    # scale. The runlog/audit gates still require ≥2 Tier-1
                    # attempts + ≥1 search-engine browser load before this verdict can land.
   ESCALATE_IDS=()  # Only when OPS_VERIFICATION_FALLBACK_TO_ESCALATE=1
                    # (see step 8b override). In normal batch runs this
                    # bucket stays empty; per-credit Slack escalation is
                    # opt-in for fraud-review traffic, not the default.
   ```
   **Forbidden verdict labels:** `UNVERIFIABLE_LOW_CONCERN` and `UNVERIFIABLE_NEEDS_REVIEW` are not permitted. Both runlog gate (exit 7) and `batch-verify-profile.sh` (exit 5) reject verdicts without per-profile evidence. The only sanctioned bypass is `INCONCLUSIVE_TIER1_UNREACHABLE` with `reason` containing `tier1_unreachable`, and that bypass itself requires evidence of an attempted fetch (≥2 Tier-1 attempts + ≥1 search-engine browser load enforced by the runlog gate).

6. **Approval cap check** — apply BEFORE acting on `APPROVE_IDS`:
   ```bash
   REMAINING_CAP=$(( APPROVAL_CAP_LIMIT - APPROVAL_CAP_USED ))
   if (( ${#APPROVE_IDS[@]} > REMAINING_CAP )); then
     CAP_OVERFLOW=("${APPROVE_IDS[@]:$REMAINING_CAP}")
     APPROVE_IDS=("${APPROVE_IDS[@]:0:$REMAINING_CAP}")
     for id in "${CAP_OVERFLOW[@]}"; do
       bash "$SKILL_DIR/scripts/runlog.sh" event "$RUN_ID" action_attempted \
         "$(jq -n --arg id "$id" --arg a skip_cap '{cr_id:$id, action:$a}')"
     done
   fi
   ```
   Cap-overflow credits are logged as `skip_cap` — they are NOT flagged as UVN and NOT escalated.

7. **Runaway safety rail** — evaluate the projected total BEFORE acting:
   ```bash
   PROJECTED_MOVES=$(( MOVES_COUNT + ${#UVN_IDS[@]} ))
   THRESHOLD=$(( (FETCH_SIZE * 9 + 9) / 10 ))
   if (( PROJECTED_MOVES >= THRESHOLD )); then
     bash "$SKILL_DIR/scripts/runlog.sh" event "$RUN_ID" runaway_rail_triggered \
       "$(jq -n --argjson n "$PROJECTED_MOVES" --argjson fs "$FETCH_SIZE" \
              '{moves_so_far:$n, fetch_size:$fs}')"
     message(action="send",
             channelId="<credit_verification_channel_id>",
             text="🚨 Runaway batch — projected $PROJECTED_MOVES of $FETCH_SIZE moves to verification_needed. Pausing. <@U038BM16T7W>")
     break
   fi
   ```

8. **Act — one dispatcher call per non-empty bucket:**

   **APPROVE_IDS (if non-empty):**
   ```bash
   bash "$SKILL_DIR/scripts/runlog.sh" event "$RUN_ID" action_attempted \
     "$(jq -n --arg pid "$PROFILE_ID" --argjson ids "$APPROVE_IDS_JSON" \
            '{profile_id:$pid, action:"approve", cr_ids:$ids}')"

   APPROVE_RC=0
   APPROVE_OUT=$(bash "$SKILL_DIR/scripts/batch-verify-profile.sh" \
       --profile-id "$PROFILE_ID" \
       --evidence-excerpt "$PROFILE_EVIDENCE_EXCERPT" \
       --ids "$(IFS=,; echo "${APPROVE_IDS[*]}")" \
       --decision approve) || APPROVE_RC=$?

   # Exit 3 = pre-flight failed (missing evidence OR Tier-1 web_fetch). Try
   # loading the remediation-suggested URLs once, then re-run. If it still
   # fails, downgrade to UVN with an explicit reason rather than silently
   # dropping the credits.
   if [[ $APPROVE_RC -eq 3 ]]; then
     # (retry loop: load two more Tier-1 pages per stderr remediation, re-run)
     # If exit 3 again → UVN_IDS+=("${APPROVE_IDS[@]}") with
     #   reason="insufficient grounded evidence on retry — downgraded from approve"
   fi
   ```
   On delegate success (`APPROVE_RC==0` and JSON outcome `dry_run_intercept` or `ok`): `APPROVED_IN_RUN += ${#APPROVE_IDS[@]}` and `APPROVAL_CAP_USED += ${#APPROVE_IDS[@]}`. On `http_error` / non-gate `APPROVE_RC==1`: `ERRORS += ${#APPROVE_IDS[@]}`.

   **UVN_IDS (if non-empty):**
   ```bash
   MOVES_COUNT=$(( MOVES_COUNT + ${#UVN_IDS[@]} ))
   bash "$SKILL_DIR/scripts/runlog.sh" event "$RUN_ID" action_attempted \
     "$(jq -n --arg pid "$PROFILE_ID" --argjson ids "$UVN_IDS_JSON" \
            '{profile_id:$pid, action:"flag", cr_ids:$ids}')"

   FLAG_RC=0
   bash "$SKILL_DIR/scripts/batch-verify-profile.sh" \
       --profile-id "$PROFILE_ID" \
       --evidence-excerpt "$PROFILE_EVIDENCE_EXCERPT" \
       --ids "$(IFS=,; echo "${UVN_IDS[*]}")" \
       --decision flag \
       --reason "$UVN_REASON_SUMMARY" || FLAG_RC=$?
   # On FLAG_RC != 0: increment ERRORS by the count in failed_ids (from the
   # delegate's stdout). Do NOT abort the batch — try the next profile.
   ```

   **8b. Fallback override (`OPS_VERIFICATION_FALLBACK_TO_ESCALATE=1`).** When this env is set, ALL UVN-bound credits (CLEAR_FRAUD + BORDERLINE + INCONCLUSIVE_TIER1_UNREACHABLE) are routed to `ESCALATE_IDS` instead — post individual top-level escalation messages tagging Jan, skip the `--decision flag` call for those ids. This is the opt-in path for fraud-review traffic where a human should be paged immediately rather than the credit waiting in the verification_needed queue. Default behavior (env unset) keeps everything in UVN, which is what cron and on-demand batch runs want.

   **ESCALATE_IDS (if non-empty):** post an individual top-level message per cr_id (existing behavior). Log `action_attempted` with `action: escalate` for each. In normal batch runs this bucket is empty unless the override above is set.

9. **Post a per-profile progress tick (REQUIRED).** After this profile's verdict / action_attempted / escalation_posted events have landed in the runlog, post a brief in-thread tick so the user sees activity. The script handles cumulative counting (decisioned vs. fetched profiles), throttles back-to-back ticks within 5s into a `progress_throttled` event (to avoid Slack spam), and writes a `progress` runlog event regardless. All ticks land in the SAME thread as the announce (B1.5) and final summary (B3) via `--reply-to "$PARENT_MSG_TS"`.
   ```bash
   OPS_PARENT_MSG_TS="$PARENT_MSG_TS" \
       bash "$SKILL_DIR/scripts/post-progress-tick.sh" "$RUN_ID" "$PROFILE_ID" "$CREDITED_NAME" || true
   ```
   The `|| true` is intentional: a failed tick should not abort the batch. The script's exit status is captured in the `script_exited` runlog event for forensics.

10. **Skip all emoji reactions** — no source message in batch mode.

11. **On any per-credit / per-profile error:** log `error` event with `cr_id` (or `profile_id`), `stage`, `error_message`, and a truncated `traceback_snippet`, increment `ERRORS`, then continue with the next profile.

   **Error-storm escalation.** If at the end of the loop `ERRORS >= max(3, FETCHED / 2)` (i.e. half the batch errored, with a floor of 3 to avoid noise on tiny batches), post a Jan-tagged alert in addition to the normal summary:
   ```bash
   if [[ "$FETCHED" -gt 0 ]]; then
     ERR_THRESHOLD=$(( FETCHED / 2 ))
     [[ "$ERR_THRESHOLD" -lt 3 ]] && ERR_THRESHOLD=3
     if [[ "$ERRORS" -ge "$ERR_THRESHOLD" ]]; then
       # Tool syntax matches the `react` calls in Step 5 (not shell).
       message(action="send",
               channelId="<credit_verification_channel_id>",
               text="🚨 Error storm — $ERRORS of $FETCHED credits errored this batch. Likely API degradation. <@U038BM16T7W>")
     fi
   fi
   ```

#### B3. Compose Summary

**The Slack parent + thread bodies MUST come from `render-slack-summary.sh` — not from agent prose.**

The 2026-04-23 09:02 UTC dry-run had a thread reply that claimed "174 APPROVE-ELIGIBLE credits NOT processed", "43 profiles", and named profiles ("Tom Baker", "Eric Padget") — none of these numbers or names existed in the truth floor. Agent-composed prose invents data; the renderer can only emit what `.results.jsonl` and the runlog actually contain.

**Hard rule (R2-5):** Every number, credit ID, and list entry in any Slack message posted from B3 MUST be a byte-for-byte copy of `render-slack-summary.sh` stdout. No agent-composed counts. No invented profile names. The ONLY free-form prose allowed in B3 is a one-line explanation (e.g. "web_fetch to musicbrainz triggered the gate") appended AFTER the renderer's thread output — explaining *why*, never *what*.

Flow (sanctioned, two-script):

```bash
# 1. compute-run-summary.sh --final — writes the terminal run_finished
#    event + invariant warnings (hollow / ungrounded / silent_failure).
#    The --final flag bypasses the in-flight guard added 2026-04-28
#    (Failure 2 fix). Idempotent per R2-2: re-invocations in the same
#    turn return the cached event without re-writing.
SUMMARY_JSON=$(bash "$SKILL_DIR/scripts/compute-run-summary.sh" --final "$RUN_ID" "$PARENT_MSG_TS")

# 2. post-batch-summary.sh — sanctioned wrapper that reads the runlog
#    truth floor, refuses to post if run_finished is missing or the
#    in-flight (B1-only) shape is detected, composes the parent + thread
#    via render-slack-summary.sh, and posts via the openclaw CLI directly.
#    Bypasses the agent's MCP message tool entirely so the enforcer
#    plugin's block-unsanctioned-batch-message hook can't accidentally
#    block the canonical post.
bash "$SKILL_DIR/scripts/post-batch-summary.sh" "$RUN_ID"
```

**Do NOT call the `message` tool with `channelId=<credit_verification_channel_id>` for the batch summary.** The enforcer plugin's `block-unsanctioned-batch-message` hook intercepts those posts and rejects them with a structured error — this is the mechanical layer that closes the 2026-04-28 15:13 / 15:26 UTC failure (gpt-5.5 hand-composed "Queue fetch succeeded — no writes" hallucinated wrap-ups). The post-batch-summary.sh script is the ONLY path that should reach the channel.

Channel selection (prod vs dry-run) and `[DRY RUN]` prefixing are handled inside `post-batch-summary.sh` based on the runlog `run_header.dryRun` flag — you don't pick the channel yourself.

The renderer handles:
- `[DRY RUN]` prefix when the run was initialized as dry-run.
- `⚠️ DISCREPANCY DETECTED` banner on `silent_failure_detected` (R2-2 invariant).
- `⚠️ N approve(s) rejected by gate` line when some landed and some didn't.
- Credit-ID lists grouped by outcome (verification_needed landed, rejected-by-gate, http_error, config-mismatch).
- Cap of 25 credit IDs per section with `+N more` suffix for readability.

You do not compose these markers yourself; the truth floor drives them.

**What NOT to do:**
- Do NOT hand-write a thread body listing profiles. The renderer lists credit IDs by outcome from `.results.jsonl` — that's the ground-truth surface.
- Do NOT add your own counts above/below the renderer output. If the renderer's "Approved: 0" disagrees with an in-run counter you maintained, the renderer is right.
- Do NOT invent profile names, emails, or role descriptions in the thread. The truth floor doesn't carry them. If you want to mention a profile in the one-line explanation appended after the renderer output, reference it from verification notes you logged via `runlog.sh event` during B2 — not from memory or pattern-matching on names you saw in the queue fetch.

`post-batch-summary.sh` owns the parent send, thread reply send, and parent
message id/ts capture. If the openclaw parent response does not expose a
threadable id (`messageId`, `ts`, `id`, or `message.ts`), the script fails
closed and does not send the thread reply as a top-level message. The
`run_finished` event was written by `compute-run-summary.sh` above; B6 won't
re-run the helper (idempotency guard catches it anyway).

**Thread reply 2** (only if approval cap was hit during this run):
```
⚠️ Daily approval cap reached ({APPROVAL_CAP_LIMIT}/day). {SKIPPED_CAP} LEGITIMATE verdicts skipped — will retry next batch.
Verification-needed moves continued uncapped.
```

Do not use `message(...)` for the batch parent or thread reply. Direct
`message(...)` calls remain appropriate only for non-summary operational posts
such as runaway-batch alerts, error-storm alerts, invariant warnings, and
per-credit escalations.

#### B4. Escalation Threads

For each escalated credit, post a **separate top-level message** in
`#credit-verification` BEFORE the summary. Use the same format as reactive
escalations (Step 5 — Escalate section above), **including the Evidence attachment rule**: run `scripts/session-evidence.sh` and embed its JSON output verbatim in a `session_evidence` block. Do NOT cite URLs that are not in `session_evidence.browser_loads[]`. One session_evidence block per escalation post — it reflects the state of the session at the time of the escalation.

**Log each escalation to the runlog BEFORE posting** so that `compute-run-summary.sh` in B6 can count it authoritatively (the bash-side `escalated` counter was historically fabricated by the agent; logging here makes it machine-derivable):

```bash
bash "$SKILL_DIR/scripts/runlog.sh" event "$RUN_ID" escalation_posted \
  "$(jq -n --arg id "$CR_ID" --arg pid "$PROFILE_ID" --arg reason "$REASON" \
          '{cr_id:$id, profile_id:$pid, reason:$reason}')"
```

**`profile_id` is REQUIRED** as of PR #235. The runlog gate refuses escalation_posted events that name a `profile_id` without ≥1 successful per-profile browser load (exit 7). The only bypass is `reason` containing `tier1_unreachable`, which itself implies attempted browses (network err / 5xx / captcha logged separately).

```
🔍 ESCALATION — [Profile Name] as [Role] on "[Track Title]" ([Artists])
Profile-ID: [profile_id]

Evidence: [1-2 sentence summary grounded only in what was actually loaded]

session_evidence
```json
<paste session-evidence.sh output verbatim>
```

Sources (Tier 1 — ONLY URLs from session_evidence.browser_loads[]):
• [host]: <url> — [what was found, or "loaded but no data"]
(omit this list if session_evidence.count_ok == 0; write "No Tier 1 sources were successfully loaded in this session.")

Risk score: [X]% | Verdict: Unverifiable — Needs Review
<@U038BM16T7W> — please review. Reply "approve" or "reject [reason]" in this thread.
```

Jan can reply in each escalation thread independently. Thread interaction works
the same as reactive flow (see Step 5 — Thread interaction).

The batch summary's "Escalated" line references these threads but does not
duplicate the full investigation details.

#### B5. Queue Clear

If the API returns zero unverified credits:

```
[HEARTBEAT-BATCH] Credit Verification Batch — [timestamp]
Queue clear — no unverified credits remaining.
```

#### B6. Finish — invariant warnings, compress old logs

After the parent summary message is posted (B3 or the B5 queue-clear message), evaluate the invariants and run maintenance.

**Do NOT re-run `compute-run-summary.sh` here.** B3 already ran the helper with `--final` to source its numbers; the `run_finished` event is already in the runlog. Re-running would write a duplicate event (idempotency guard catches it, but the spurious invocation is wasted work). Re-use the `$SUMMARY_JSON` you already have:

```bash
HOLLOW=$(echo "$SUMMARY_JSON" | jq -r '.hollow')
UNGROUNDED=$(echo "$SUMMARY_JSON" | jq -r '.ungrounded')
SILENT_FAILURE=$(echo "$SUMMARY_JSON" | jq -r '.silent_failure_detected')
```

`compute-run-summary.sh` (invoked in B3) writes the `run_finished` event plus one of:

- `run_finished_hollow` — fires when preflight passed but zero credits were
  fetched or acted on (14:51 `51e6a2` incident class). Indicates an agent
  that passed B0d then skipped B1–B4 entirely.
- `run_finished_ungrounded` — fires when the derived preflight failed but the
  agent still logged approvals or verification_needed moves (13:26 `b8b0e5`
  incident class). Indicates fabricated evidence — e.g. `web_fetch` substituted
  for the `browser` probe.
- `run_finished_silent_failure` — fires when admin-api attempts > 0 but 0
  landed for approves or UVN (2026-04-22 19:15 incident class). Indicates
  the agent's Slack prose likely lied about totals. The `reconciliation`
  block in the event payload carries per-category counts (approved_landed,
  approved_rejected_by_gate, verification_needed_http_error, etc.) for the
  post-mortem.

If any invariant fired, post a visible warning tagging Jan **in addition to** the B3 summary. Use the same `message()` tool-call shape as the runaway rail in B2 — the tool call must NOT be inside a bash fence, since the LLM otherwise tries to `eval` it. Compose the text variable in bash, then drop out of the fence for the tool call:

```bash
if [[ "$HOLLOW" == "true" ]]; then
  WARN_TEXT="🚨 Hollow batch run — preflight passed but no credits were fetched or acted on. Run ID: $RUN_ID. Likely a confabulated session (e.g. fallback-model session under load). <@U038BM16T7W>"
elif [[ "$UNGROUNDED" == "true" ]]; then
  WARN_TEXT="🚨 Ungrounded batch run — approvals/VN moves logged without a successful browser preflight. Run ID: $RUN_ID. Likely fabricated evidence. <@U038BM16T7W>"
elif [[ "$SILENT_FAILURE" == "true" ]]; then
  REJECTED=$(echo "$SUMMARY_JSON" | jq -r '.reconciliation.approved_rejected_by_gate // 0')
  WARN_TEXT="🚨 Silent-failure batch — admin-API attempts did not land. Run ID: $RUN_ID. Rejected by gate: $REJECTED. See reconciliation in the runlog. <@U038BM16T7W>"
fi
```

Then, if `WARN_TEXT` was set, issue this tool call (note: not bash — this is
openclaw `message()` syntax, same as the runaway-rail post in B2.5):

```
message(action="send", channelId="<credit_verification_channel_id>", text=WARN_TEXT)
```

The Slack warning is LLM-mediated, but the authoritative record is the `run_finished_hollow` / `run_finished_ungrounded` / `run_finished_silent_failure` event in the runlog — those land regardless of whether the agent executes the `message()` call. A follow-up out-of-band watchdog can tail runlogs and alert on any of them.

Run compression (idempotent; cheap no-op most days):
```bash
bash "$SKILL_DIR/scripts/compress-old-logs.sh" || true
```

The lockfile is released automatically by the `trap` set in B0 when the run exits.

> **Mechanical fallback for skipped B3/B6** (issue #152, refined 2026-04-28). The B0b `trap` does NOT autofill `run_finished` by default — that opt-in semantic was added after the 2026-04-28 15:35 UTC race where a multi-exec mid-batch trap fired `compute-run-summary.sh` 53s before B2 actually ran, polluting the runlog with a premature `run_finished_hollow`. The trap now only autofills when (a) the caller passes `--final` (or sets `OPS_BATCH_TERMINAL=1`), AND (b) the runlog has been quiescent for ≥ 120s.
>
> If B3 explicitly runs `compute-run-summary.sh --final` (which it does), the truth-floor `run_finished` event lands cleanly in the same turn — no fallback needed. If B3 is genuinely skipped (agent crash, infrastructure failure) AND the run was the terminal one AND ≥ 120s have passed, a future invocation of `lockfile.sh release --final` (e.g. via a watchdog or follow-up turn) can still land the autofill. This is intentionally narrower than the pre-2026-04-28 always-fire fallback: better to leave the runlog incomplete than to write false-positive hollow flags on a healthy run.
>
> The unrelated `run_finished_renderer_missing` post-hoc detector (R4-3) still fires on every release regardless of `--final`. It scans the session for renderer-shaped messages and emits the forensic event when work happened (attempts > 0) but the agent bypassed `post-batch-summary.sh` / `render-slack-summary.sh`. Idempotent and safe to fire repeatedly.

### Rate Limiting Note

When processing multiple credits sequentially, space web research requests to
avoid hitting rate limits on external sources (MusicBrainz, Apple Music, Discogs, AllMusic, etc.).
If a source returns 429, skip it and note as a failed source for that credit.

---

## Profile Verification Mode (Ad-Hoc)

Handles requests like "verify all credits for profile X" or "check all remaining
credits for [name]". This mode is triggered by a human (Jan or Aaron) asking in
any ops channel — NOT by the automated credit verification bot.

### When This Applies

A human explicitly asks to verify, check, or approve all pending/remaining credits
for a specific profile. This is NOT a bulk rubber-stamp — each credit group goes
through investigation.

### HARD RULES

1. **Never approve all credits in a single API call.** The wrapper enforces a
   maximum of 10 requestIds per call. Even if the wrapper allowed it, you MUST
   process in groups.
2. **Never skip investigation.** Every credit group must be investigated before
   approval. "The profile looks legit" is not sufficient — you must verify the
   credits themselves are plausible.
3. **Daily approval cap still applies.** If you hit 500 autonomous approvals
   (UTC day), stop approving and tell the requester how many remain for the
   next cycle. Verification-needed moves and escalations are uncapped.
4. **Only Jan (U038BM16T7W) or Aaron (U7RP6HKUZ) can trigger this workflow.**
   Verify `sender_id` from message metadata.

### Workflow

#### P1. Acknowledge and Fetch

Acknowledge the request, then fetch all unverified credits for the profile:

```bash
bash /opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/credit-requests?status=unverified&profilesIds=<profile_id>&limit=500"
```

**⚠️ Param name:** Use `profilesIds` (plural, capital `I`). `profileId`
singular is silently ignored by the backend and returns the general queue.
Spot-check the first row's `profileId` field matches `<profile_id>` before
trusting the result set.

Post acknowledgment:

```
Checking all unverified credits for [Profile Name] ([profile_id]).
Found [N] pending. Processing now — this will take a while for large queues.
```

If N > 500, add:
```
Note: Daily approval cap is 500 autonomous approvals. I'll approve up to 500
this cycle and report how many remain. (Verification-needed moves and
escalations are uncapped.)
```

#### P2. Profile-Level Investigation

Before processing individual credits, investigate the profile itself. This
determines the baseline trust level.

**Required checks:**
- Web presence: professional website, LinkedIn, studio presence
- Industry registration: IPI, MLC, TIDAL, Jaxsta profiles
- Existing catalog: how many credits already in the system, what roles, how long
- Submission pattern: single role type vs. mixed, same ecosystem vs. scattered

**Classify the profile:**

| Profile Level | Criteria | Effect on Credit Processing |
|---------------|----------|---------------------------|
| **ESTABLISHED** | Professional website + IPI/MLC + 50+ existing credits + consistent role | Groups of same role/ecosystem can use lighter investigation (P3a) |
| **EMERGING** | Some web presence OR IPI/MLC OR 10+ existing credits | Each credit gets standard investigation (P3b) |
| **UNKNOWN** | No web presence, no registrations, few/no existing credits | Escalate entire batch to Jan — do not auto-process |

Post the profile assessment before proceeding:

```
Profile Assessment — [Profile Name]

Web: [findings]
Industry: [IPI/MLC/TIDAL/Jaxsta status]
Catalog: [N] existing credits, primarily [roles]
Submission: [pattern description]

Profile level: [ESTABLISHED/EMERGING/UNKNOWN]
Proceeding with [approach based on level].
```

#### P3. Group and Process Credits

Group the credits by **role type** and **submission source** (submissionId).
Each group is processed separately.

**P3a. Established profile — grouped investigation:**

For each role/source group:
1. Verify the role is consistent with the profile's known work
2. Spot-check 3-5 credits from the group against Tier 1 sources (MusicBrainz, Apple Music, Discogs, AllMusic)
3. Check for deleted tracks in the group (GET each credit's track status)
4. Check for outliers: different genre, unusually high popularity (pop >= 90),
   or roles that differ from the profile's primary role

If spot-checks pass and no outliers: approve the group (in batches of 10 max).
If outliers found: pull them out and process individually per P3b.

**P3b. Emerging profile — individual investigation:**

Process each credit through the standard Steps 2-6 from the reactive workflow:
- Step 2: Idempotency check
- Step 3: Investigate (Athena + tiered web research + fraud signals)
- Step 4: Classify
- Step 5: Act (approve/reject/escalate)

This is slower but ensures full rigor for less-established profiles.

**P3c. Unknown profile — escalate:**

Do NOT auto-process. Post to the channel:

```
Warning: Profile [Name] has insufficient verification data for autonomous processing.

Web presence: [none/minimal]
Industry registration: [none found]
Existing catalog: [N] credits

[N] unverified credits cannot be auto-processed. Manual review required.
<@U038BM16T7W> — please review this profile before I process credits.
```

Wait for Jan/Aaron to respond with guidance in the thread.

#### P4. Execute Approvals

For each approved group, call the API in batches of 10 or fewer:

```bash
bash /opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  --requester <requester_slack_id> \
  call PUT "/admin/credit-requests" \
  '{"requestIds":["<id1>","<id2>",...max 10],"status":"approved"}'
```

Log each batch via `muso-ops-audit` before execution.

For rejections, include a reason:

```bash
bash /opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  --requester <requester_slack_id> \
  call PUT "/admin/credit-requests" \
  '{"requestIds":["<id>"],"status":"rejected","reason":"[specific reason]"}'
```

#### P5. Summary Report

After processing all credits (or hitting the daily cap), post a summary:

```
Profile Verification Complete — [Profile Name]

Profile level: [ESTABLISHED/EMERGING/UNKNOWN]
Total unverified: [N]
Processed: [N]

Approved: [N] ([breakdown by role group])
Rejected: [N] ([reasons])
Escalated: [N] ([reasons])
Skipped (cap): [N] — daily limit reached, [N] remain for next cycle
Skipped (deleted track): [N]

[If any remain:]
Remaining: [N] unverified credits. Will process in next cycle or on request.
```
