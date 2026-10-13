# Credit-verification channel: full routing rules and the incidents behind them

Moved out of `SOUL.md` on 2026-08-28 because that file had grown past the boot
injection cap (`bootstrapMaxChars`) and openclaw was silently dropping a band out
of its middle. Nothing here changed in the move -- this is the section verbatim.
The binding one-liners stayed in the SOUL as a routing table; this file carries the
detail and the incident history that made each rule necessary.

Read this when a #credit-verification message is ambiguous, when a routing call is
contested, or when you want the reason a rule exists rather than the rule.

## Credit Verification Channel Rule (#credit-verification / C0APB2CMM7C)
This channel behaves like every other channel: **@mention is required**
(`requireMention: true` in openclaw-main.json). The
old auto-fire-on-every-message behavior is gone, and the core-backend
auto-post integration (Block Kit messages on risk-score ≥ 85%) was
removed — there is no longer a bot feeding messages into this channel.

When the agent IS @mentioned in #credit-verification with a credit
request to verify (e.g., `credits.muso.ai/profile/<uuid>/credits-submissions`
URL, list of credit IDs, or specific user/profile to check), route to the
`muso-ops-credit-verification` skill: parse, investigate, classify, act,
report. The cron batch mode (4-hourly API fetch → process → summary)
remains the other live trigger.

### "fastlane" is NOT credit verification — route to `muso-ops-fastlane`
If a message says **fastlane** / **fast lane** / **fast-lane** (with one or
more profile UUIDs/URLs), it is a **profile analytics bootstrap**, NOT a credit
request. Route it to the `muso-ops-fastlane` skill, which fires
`POST /admin/analytics/<profileId>/fast-lane`. This holds even when the message
also mentions credits, analytics, streams, or "verify" — the word *fastlane*
wins. NEVER run `muso-ops-credit-verification` / `dispatch-cv-batch.sh` /
"run credit verification" for a fastlane request. (Jan has repeatedly been given
the wrong one — 2026-06-07: "i said fast lane, not credit verifiation".) Jan is
self-authorized for fastlane; fire immediately. The `muso-ops-fastlane` skill
owns **both** the plain lane and the **fastlane+** superset (`fast-lane-plus`,
plus a per-user variant) — the skill picks the lane: numbers stale → plain;
tracks/credits **missing** → fastlane+.

### "fix the tracks" / artwork / credit details is CATALOG metadata, NOT credit verification
If a message asks to **fix tracks**, fix/missing **artwork**, or fix/missing
**credit details** on a profile's tracks (track/profile URLs or IDs), it is a
**catalog track-metadata** task — handle it with the `muso-ops-tracks` skill
(e.g. `POST /admin/track/enrichByUrl`, `POST /admin/track/capture/<id>`), NOT
credit verification. NEVER run `muso-ops-credit-verification` /
`dispatch-cv-batch.sh` for it — that verifies credit *requests*, a different
thing. (2026-06-08: Jan asked to "fix the tracks artwork, credit details" and
got a credit-verification batch — "i did not said you verify the credit. I said
fix the tracks".) Do NOT invent a ticket ID or a human handoff (no "Rio",
no "Catalog/Verification queue", no ClickUp id) — those are fabrications; see the
honesty doctrine below. And an enrich/capture HTTP **200 is not proof the fix
landed** — the repair is **async** (200 = queued, not done). An empty read-back
right after the 200 (`pending=true / name=null`) is the normal in-flight state,
NOT a failure: **wait and re-check** per the `muso-ops-tracks` "Fix missing
artwork / credit details — full recipe", and report three states — `materialized`
/ `still pending` (give a re-check time) / `cannot enrich (no Spotify match)`.
Only escalate to Nick when a track that HAS a resolved Spotify source stays empty
well past the window (~1h) or reads 500 — a genuine pipeline bug. Do not report a
fresh in-flight repair as "failing".

**"Wait and re-check" only applies to a capture that can actually LAND. Check the
call shape BEFORE you wait.** A profile capture attaches only when the request
carried `profileId` (`POST /admin/profile/enrichByUrl`); `POST
/admin/artist/<spotifyId>/enrich` carries no profile reference at all. Without
that link the capture is still `accepted:true` with a `captureId`, and then
attaches to nothing — forever. Re-checking cannot resolve it, so a third
"still pending" report is not diligence, it is a missed diagnosis
(2026-08-05: profile `ylsvoid` escalated three times before anyone noticed the
call itself could never work). If a profile source has not appeared, first ask
"did that call name the profile?" — if not, re-issue it correctly instead of
waiting or escalating. The admin wrapper now refuses the unlinkable shapes
outright; read its refusal text, it names the correct call.

### Ghost/source-less catalog rows are TRACK MERGE cleanup, NOT credit removal
If a request says a profile credit is attached to a placeholder, ghost,
duplicate, source-less, no-Spotify, no-ISRC, or no-artist track row, handle it
with `muso-ops-tracks` as a **track merge investigation**. Do NOT delete the
track, do NOT remove/re-add the profile credit as the primary fix, and do NOT run
credit verification. The normal fix is to merge the source-less catalog loser
into the proven source-backed survivor so the existing profile credit moves with
the catalog row.

Required guardrails:
- Pre-read the ghost row and candidate survivor row before any write.
- Treat `mergeInto` as the survivor that must be kept, and `tracksIds` as the
  source-less loser list.
- Only merge when title plus source metadata prove the match: artists, Spotify
  ID, ISRC, album/release date, or equivalent source evidence.
- If many same-title catalog rows exist, hold the merge until the survivor is
  proven; never pick a survivor from title alone.
- After the merge, read back both the old ghost ID and the survivor ID, then read
  the profile credits. A clean result means the old ID resolves to the survivor,
  the survivor has source metadata, and the profile credit appears on the
  survivor while the ghost ID no longer appears as a profile credit row.

### "UVN" / "Verification Needed" review is NOT credit verification
If a message asks to review, validate, or resolve **UVN** /
**user verification needed** / **"Verification Needed"** credits or tracks
(often alongside ClickUp tickets or an Intercom conversation), that is a
**manual per-request review of credits already in `user_verification_needed`**,
NOT a batch run. NEVER run `muso-ops-credit-verification` /
`dispatch-cv-batch.sh` for it: the batch selector fetches ONLY
`status=unverified` credits, and UVN credits are by definition past that
state — so every dispatch is a guaranteed "Sampled: 0" no-op. (2026-07-22:
Jan asked to validate UVN tracks from ClickUp TO DO profiles; the agent
dispatched the batch once per profile — ~30 no-op runs in ~2 minutes, each
posting a full summary block, until Jan and Nick had to intervene.)

Correct routing for a UVN ask:
- **`muso-ops-credits`** — list the profile's UVN requests
  (`GET /admin/credit-requests?...status=user_verification_needed`), review
  each against evidence, then `PUT` approve per the credit-approve gate — or
  **leave the request in `user_verification_needed` and document what proof is
  missing**. NEVER reject autonomously: rejection is a one-way door (the
  backend has no rejected→UVN transition; incident 2026-07-22, 28 requests)
  and the reject gate in muso-admin-api.sh blocks it without
  `--confirmed-by <jan|aaron|nick> --approval-msg-id`. Recommend rejects to
  Jan in-thread instead. Read back every status change — a 200 is not proof
  the transition landed.
- Evidence gathering: **`muso-credit-investigator`** (GRANT/DENY/ESCALATE
  recommendation per request) and/or **`muso-audit-profile-credits`**
  (per-track verdicts on a profile).
- ClickUp tickets + Intercom context + "mark Resolved" wrapper:
  **`muso-clickup-ticket-sweeper`**.

Related hard rule (enforced in code): `dispatch-cv-batch.sh` is
**one-dispatch-per-request** — it processes its whole selector in a single
run. Never iterate it over a list of profiles; a repeat-dispatch guard in
the wrapper refuses rapid re-dispatch (exit 2) and must NOT be retried or
worked around.

**Output rule:** Only post the final structured report (Step 6 format) to the channel thread.
Never post internal reasoning, step numbers, parsing status, API debugging, or investigation
narration. All intermediate work (parsing, API calls, web research) happens silently — the
human only sees the final verdict with evidence and source links.

## Never name the internal thread to a customer

**Nick's decision, 2026-10-08: stop citing `platform-data-processing` #2405 to customers.**
It had been quoted as the place credit-verification requests are handled. It is not: the
thread has no responder, and three requests filed there were never answered, so quoting it
promised something we do not keep.

The rule is wider than that one thread: **no internal thread, issue, repo or link is ever
named to a customer**, and "it's open on our side" phrasing that points at one is the same
mistake in different words. Say only:

> "We're looking at it and will come back to you."

— or name a channel that has a human on it. Quote the normal SLA once, never an engineering
ETA. Who answers #2405 is a separate, open question and does not change this rule.

Internal refs stay internal: #2405 remains the mailbox for filing requests, and an internal
Intercom note (`intercom-ops-write.sh note`) may carry the link freely. Only the
customer-facing reply may not.

