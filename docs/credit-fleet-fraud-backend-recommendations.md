# Credit "Fleet Fraud" — backend gate recommendations

**Audience:** the core-backend + industry-data-processing (IDP) team.
**Author:** hydra/ops (Nick), from the 2026-06-03/04 incident analysis.
**Status:** recommendations. Tracked as **Muso-AI/core-backend#8837** (enforce score + close ops
bypass) and **Muso-AI/industry-data-processing#1260** (tighten graduation + hard gate). Hydra is
building the *detection/alerting* and *retroactive sweep* side in parallel (see "Division of work"
at the bottom); the **hard enforcement gate can only live in the backend** — that's what this doc
specs.

> Every file:line below was read directly from the `develop` checkout of `core-backend` and
> `industry-data-processing` on 2026-06-04. Rule/class/function names are stable; line numbers are
> as-of-that-date.

---

## 1. What happened (one paragraph)

A **free, $0-LTV** account (`userId 162720`) got a contested claim on a real-but-tiny profile —
**T L A / "KSJ Beats"** (`9703c867…`) — *processed* in Oct 2025, then injected **~1,100 fraudulent
Producer/Writer credits** onto unrelated superstar catalogs (Olivia Rodrigo ×39, Noah Kahan ×15,
Ariana ×14, Drake…), reaching ~**#1 on the Producer chart**. ~1,340 of the approvals (≈68%) were
rubber-stamped through the **Retool/Clio ops queue** (`operations:clio:admin_u`,
`operations:retool:*`). This is a *class* of abuse ("credit fleet fraud"), not a one-off — several
other profiles match the same signature.

## 2. Why it worked — four compounding gaps (all code-verified)

### Gap 1 — the automated "graduation" rules bypass the risk score
`IDP/processors/raw/validation/credit_validation_rules.py` has three **auto-approve** rules that
return `0.0` (zero risk) and short-circuit the entire weighted score:
- `ProfileOwningTracksValidationRule` (:76) — profile is an artist on the track, or a member of an
  artist on the track.
- `ProfileCreditExistsValidationRule` (:94) — the same credit already exists (raw `RawRecordingCredit`
  or catalog `CatalogTrack` master).
- **`ProfileCommonCollaboratorValidationRule` (:177, `MIN_COMMON_CREDITS = 2`, :179/:191)** — the
  profile has **≥2 credits on *other* tracks by the same artist** ⇒ **every future track by that
  artist auto-approves.**

So once two Olivia-Rodrigo credits exist for a profile, *all* her tracks auto-approve — the
`ProfileTrackPopularityValidationRule` (:196), `TrackCreditValidationRule` (:290, where Producer/
Songwriter is high-risk), and `ProfileTrackArtistPopularityValidationRule` (:322) penalties **never
apply**. (`profile_credit: 100` from the incident Slack is the `ProfileCreditValidationRule` (:272)
emitting max risk for a never-seen credit type — exactly the signal that gets bypassed.)

### Gap 2 — the ops/admin path skips ALL validation, and *seeds* the graduation
- **IDP:** `muso_processor.py:128` — `if action_by.type == ActionType.user:` gates the whole
  validation block. Ops submissions (`action_by.type == operations`, e.g.
  `operations:retool:<email>`) skip it: `is_validation_success` stays `True` (:125) and the credit is
  saved unconditionally (:160-168), with the callback reporting success (:171-179).
- **core-backend:** the admin approve endpoint `src/apis/_admin/credit-requests/updateStatus.js`
  (the Retool/Clio path) flips `status → approved` and calls `addCreditsToTracks()` (:100) with **no
  checks**. Its `profileId` bulk branch (:57-60) approves **all** `unverified` rows for a profile in
  one call (→ "598 approved in one window").
- A third **side-door**, `src/apis/_admin/track/addTrackProfileCredits.js`
  (`POST /admin/track/:trackId/profile/:profileId/credits`), materializes credits **bypassing
  `credit_requests` and the validator entirely**.

Each manual ops approval also *seeds* the Gap-1 rules: once a couple of credits exist, the
graduation rules cascade the rest automatically.

### Gap 3 — the risk score is computed but advisory at the human layer
`credit_requests.verificationData.total_risk_percent` (0-100) is stored, **indexed**
(`migrations/…risk-index`), and filterable in the admin UI (`list.js` `scoreBiggerThan`). But
`updateStatus.js` never reads it, and **`status = approved` can be set while
`verificationData.is_approved = false`** with no audit — the 632 contradictory rows the incident
surfaced. (`updateStatus.js` writes only `status`; `verificationData` is written by the IDP callback
`updateProfileCreditRequest.js:46-49`. Nothing reconciles the two.)

### Gap 4 — there is no user/workspace-level ("fleet") detection anywhere
IDP validation is strictly per-(profile, track, credit) — `UserCreditValidator(profile_id, track_id,
credits)`; `CatalogProfile` has no `user_id`. The only place the **user ↔ workspace ↔ profile ↔
credit join exists is core-backend** (`credit_requests.userId/workspaceId`, `credit_submissions`,
`claiming`), and nothing scores it. So "one user spraying 1,100 credits across unrelated superstars"
is structurally invisible to every existing check.

## 3. Recommendations (grafted onto the in-flight risk-tier PRs)

These build on Nick's open stack — **don't rebuild**:
- **IDP #1093** `new-risk-score` — score-correctness (removes a popularity double-count, abstain,
  fail-closed). **Approved but currently CONFLICTING — needs rebase.**
- **IDP #1096** `feat/credit-risk-validator-outcome` — the `approved | user_verification_needed |
  unverified` outcome enum + env-tunable thresholds (`CREDIT_APPROVE_THRESHOLD=30`,
  `CREDIT_USER_VERIFY_HI_THRESHOLD=60`). Stacked on #1093.
- **core-backend #8689** `feat/credit-risk-tier-consumer` — consumes the outcome enum (fail-closed
  `aggregateOutcome.js`) + a user self-service `confirm/not_mine` endpoint. **DRAFT, flag-off**
  (`CREDIT_USER_VERIFICATION_TIER_ENABLED`).

### Prerequisite — retune the threshold when landing #1093 (fraud-relevant, not just queue-tuning)
#1093 removes a hidden `log10(track_pop+1)` multiplier, dropping scores on popular tracks **~2-3×**.
Against the unchanged `CREDIT_APPROVE_THRESHOLD=30` this **loosens** auto-approval — the opposite of
what we want for fraud. **Raise `CREDIT_APPROVE_THRESHOLD` (≈60-80) at the same time** and monitor the
outcome distribution (#1096 already emits the metric) for 1-2 weeks. Do not ship #1093 alone.

### A — close the ops/admin validation bypass
- **IDP** `muso_processor.py:128`: do **not** skip validation when `action_by.type != user`. Run the
  same `UserCreditValidator` for ops/Retool submissions (or, at minimum, the hard gate in D). Ops
  convenience must not be a validation exemption — that exemption is how ~68% of these credits got in.
- **core-backend:** route the side-door `addTrackProfileCredits.js` and the materialization helper
  `services/credits/addCreditsToTracks.js` through the same gate, so neither the admin endpoints nor
  the direct track-add can materialize an un-validated credit.

### B — make the risk score enforce (kill the "approved while is_approved=false" class)
Refuse `status = approved` when `verificationData.is_approved === false` (or
`total_risk_percent ≥ HARD_THRESHOLD`) **unless** an explicit, **audited** override is supplied
(operator id + reason, persisted on the row / audit log). Put it behind a new
`CREDIT_RISK_HARD_GATE_ENABLED` flag for safe rollout, at **both** write paths:
- `updateProfileCreditRequest.js` (the IDP callback path) — extend #8689's `aggregateOutcome` triage:
  if `outcome === 'approved'` but `is_approved` is false / corrupt, demote to `UNVERIFIED` + escalate.
- **`updateStatus.js` (the admin/Retool path — the one the fraud actually used; #8689 does NOT touch
  it).** Add the same guard in the `APPROVED` branch (:85-108) before `addCreditsToTracks()`. This is
  the single highest-leverage change in this doc.

### C — tighten the graduation rules (IDP #1096 substrate)
In `credit_validation_rules.py`:
- `ProfileCommonCollaboratorValidationRule` (:177): only **source-verified, non-user-added** prior
  credits should count toward `shared_track_count` (today any prior credit — including a
  fraudulently-approved one — builds trust, which is precisely the graduation exploit). Also consider
  raising `MIN_COMMON_CREDITS` (2 → higher) and/or requiring the profile to *own* one of the shared
  tracks.
- `ProfileCreditExistsValidationRule` (:94): the "credit already exists" auto-approve should not fire
  when the existing credit was itself user-added and unverified (don't let a prior bad approval
  whitewash the next one).
- Hard rule: **never auto-approve** Producer / Writer / Manager / Co-* roles on `popularity ≥ 70`
  tracks regardless of any graduation rule (implement as part of D).

### D — add a hard popularity/name-mismatch auto-reject (IDP #1096 substrate)
Add a new `auto_reject` rule to `RULES_CONFIG` **before** the auto-approve rules (so it
short-circuits graduation), e.g. `reject_high_pop_name_mismatch`: reject when the credit role is
high-risk (Producer/Writer/Manager/Co-*) AND `track.popularity ≥ 70` AND the profile name does **not**
fuzzy-match any of the track's primary-artist names. `ProfileTrackPopularityValidationRule` (:196)
today is a *soft* score, not a gate — this adds the hard floor Aaron asked for. (core-backend already
carries `spotifyPopularity` + `spotifyTrackArtists` on every `credit_requests` row, so a
backend-side backup gate is also cheap if you want defense-in-depth.)

### Also
- **Cap concurrent open claims/requests per user/workspace** (Aaron's "MLC ≤ 100 at a time").
- **Chart-publish exclusion** for profiles with unresolved credit-risk debt (so a future chart
  restore can't crown an un-remediated fraud).
- **Expose #8689's `not_mine` user-response signal** (`metadata.user_response`, audit event
  `credit_request.user_response`) to the hydra fleet detector — multiple `not_mine` across a
  user/workspace is a strong fleet signal.

## 4. Suggested merge sequence

1. **IDP #1093** (rebase) **+ `CREDIT_APPROVE_THRESHOLD` retune** — together, never separately.
2. **IDP #1096** (outcome enum) → then land **C** + **D** as new/tightened rules on top of it.
3. **core-backend #8689** (consumer, flag-off) → then land **B** (both write paths) behind
   `CREDIT_RISK_HARD_GATE_ENABLED`, and **A** (ops bypass) — flip the flags after the outcome
   distribution looks right in shadow.

## 5. Division of work (so we don't collide)

- **Backend team (this doc):** the hard gate — A, B, C, D — the only place the admin/Retool path can
  be stopped.
- **Hydra/ops (in progress):** (1) a **scheduled user-level fleet-fraud detector** (warehouse scan →
  ranked Slack alert for analyst review; advisory, no auto-action), and (2) a **retroactive sweep +
  gated bulk-reject** over the immutable Jun-2 snapshot to find and back out existing damage. These
  *detect and remediate*; they do not replace the backend gate.
