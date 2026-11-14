# Where hydra code ends at a person today

Read 2026-11-13 20:20Z at `452d405dc`, for the standing rule "no verification path may end at a person".

Method: one pattern search over `scripts/`, `plugins/`, `skills-all/`, `workspaces/` (tests excluded) for
`needs_human`, `human_review`, `route_to_human`, `queue_tier2`, `JAN_*`, `DMCA_REVIEW`, `jan_review`, `named human`,
`a person decides`, `held for a human`; then the hit lines read in the files below. A route written in other words
is not in this list. core-backend was not read.

## 1. GDPR, takedown and hide (this lane changes these)

| Where | Outcome today | Ends at |
|---|---|---|
| `scripts/gdpr_pipeline/identity.py:203` | `DMCA_REVIEW`: takedown notice, requester holds no claim | "copyright review", no owner in code |
| `identity.py:206` | `JAN_BIGNAME`: legal threat on a big profile | Jan |
| `identity.py:207` | `LEGAL_HIDE_FIRST`: legal threat on a small profile is hidden with no identity step | the captain's `--include-legal` run |
| `identity.py:273-304` | `JAN_REVIEW` / `JAN_BIGNAME` for a track or album (9 branches) | Jan |
| `identity.py:189` | `GONE`: "a person confirms what happened before any letter" | Jan |
| `identity.py:334-338`, `action_for` | the action text for each of the above, and "read the mail thread" | Jan / a reader |
| `scripts/gdpr_pipeline/run.py:644` | a row with no page decision becomes `JAN_REVIEW` | Jan |
| `scripts/gdpr_pipeline/sources.py:236` | unread item: "a person decides the scope" | Jan |
| `scripts/gdpr-triage-bridge.py:75,599,630` | `HUMAN_ALWAYS` = legal threat, DMCA: outcome `human_review` | staff |
| `scripts/gdpr_pipeline/hide_batch.py:5,230,346,416` | the hide PRs are opened `no-automerge`; "a person merges" | whoever merges |
| `hide_batch.py:147-167,293` | legal hides wait for the captain's `--include-legal` | Aaron |
| `scripts/gdpr-pipeline.py:482,637-650,725-741`, `gdpr_pipeline/approval.py` | a confirmation letter needs an allowlisted Slack id plus that person's Slack message | Aaron / Jan / Nick, or the one approved sender seat |
| `scripts/gdpr-pipeline.py:252-324` | `resolve` of an uncertain send requires `--by` a person | staff |
| `scripts/gdpr-pipeline.py:8` | `tick --page`, `watchdog --page` post to #cs_priority | Jan |
| `policies/gdpr-dsar-copy.json` | `denial`, `extension_complexity` are locked; `dsar extend` needs a recorded ruling | a ruling |

Also still hide-eligible in code and tied to nobody: `identity.py:45` keeps `PASS_B` and `PASS_C` (a name match) in
`HIDE_ELIGIBLE` and `IDENTITY_PASS`. No branch returns them since 11-12, but a row that carries one is still batched.

## 2. Claims

| Where | Outcome today | Ends at |
|---|---|---|
| `scripts/claim_verify/doc_ladder.py:79,96-116` | `needs_human_review` for 20 reason codes (claimant not named, profile already claimed, document forged, releases not on profile, account hold, ...) | a queue nobody is assigned |
| `doc_ladder.py` `release --by NAME` | a standing approved/refused row is released only by a named person | staff |
| `plugins/support-tools/src/tools/profile-claim-status.ts:72,180,232-241` | `human_review`: reverted claim, several claims, unknown state, profile claimed by another workspace | hand-off ticket |
| `plugins/support-tools/src/tools/profiles-claim-self.ts:116` | `owner_undetermined`: "routed for human verification" | hand-off |

## 3. Credits

| Where | Outcome today | Ends at |
|---|---|---|
| `scripts/credit_review/policy.py:47,301,305,322,329,375` | `NEEDS-HUMAN`: red flags, undecided, catalog-only, model error, model said so | staff |
| `scripts/credit_review/scale_drain.py:107-108,608,623,2176` | `queue_tier2`: every refusal (precedent refuse, proof refuse, expired with no proof); `tier2-queue` lists them | a named human with `--confirmed-by` |
| `scripts/credit_review/decide.py:102,802,820,3057,3142` | `skipped:needs_human_review`; a document on file holds the credit "for a human" | staff |
| `scripts/credit_review/verify_notify.py:292-319,570,613,2591` | held for a human: document on file, org affiliation unknown, emailed support@, past reply-by date; reason `verification` is `manual_only` | staff |
| `scripts/credit_review/uvn_status.py:36,1217,2040` | a note refused 3 times is "flagged to #cs_priority for a human" | Jan |
| `scripts/credit_review/decline_close.py:219,254,303` | `hold`: "a person decides" | staff |
| `scripts/credit_review/reply_ref_picker.py:61,200-207` | `jan_review`: legal, chargeback, dispute | Jan |
| `scripts/credit_review/doc_approve.py:28,1432,1722`, `scripts/credit-retro.py`, `scripts/credit_retro/` | a reversal or take-back runs from a named human's own session (core refuses agent tokens on removals) | staff |
| `scripts/clickup_drain/bulk_credit_change.py` `--revert` | prints a plan for a named human | staff |
| `plugins/support-tools/src/tools/credits-verify.ts:123`, `profile-credits-status.ts:117,197,245` | `human_review` / `owner_undetermined`: impersonation flag, credit on another profile | hand-off |

## 4. Proof documents

| Where | Outcome today | Ends at |
|---|---|---|
| `scripts/credit_verify/docverify/tray.py:1,18,380` | the reader's trays; the first 20 per outcome "confirmed by a named human" | staff |
| `scripts/credit_verify/docverify/intel.py:16` | "evidence for a human, never an outcome" | staff |

## 5. Merges

| Where | Outcome today | Ends at |
|---|---|---|
| `scripts/merge_verify/rules.py:29,80,143,199,372` | `needs_human:<why>` (big, common or flagged profile); `eligible` prints a command "a named human runs" | staff |
| `plugins/support-tools/src/tools/profiles-consolidate.ts:167,180` | `owner_undetermined`, routed to a human | hand-off |

## 6. Support and the Ops bot

| Where | Outcome today | Ends at |
|---|---|---|
| `plugins/intercom/src/assignment-policy.ts:323` | `QUEUE_ESCALATION_REASONS`: seven reasons leave Caroline for the team queue | a queue with no members |
| `scripts/ops_intake/answer.py`, `router.py` | a W2 ask (delete, merge without manifest, approve, refund) is refused with "the human path" named; an unreadable fact falls to the hand-off | staff |

## What this lane does with it

Section 1 only, and only part of it. What changed: the hide guard (`scripts/gdpr_pipeline/hide_guard.py`) admits a
page on ownership alone and has no outcome that waits for a person; a requester whose claim does not show ownership
is decided `ASK_IDENTITY`; hide-first on a legal threat is no longer a way to a hide.

What did not change: every row in section 1 that ends at a person still does. `JAN_REVIEW`, `JAN_BIGNAME` and
`DMCA_REVIEW` are still verdicts in `identity.py`; none of them reaches a hide, and none of them asks the requester.
One open request moved INTO that queue under this change: register 369, an album whose artist no longer passes
(`identity.decide_item` gives no ask, because the approved ask copy is about a profile). Turning those verdicts into
asks needs customer copy for a track, an album, a takedown notice and a legal threat, each through the copy gate.
Sections 2 to 6 belong to the lanes that own those paths; nothing there is changed here.

One step this lane does not change: the two hide PRs are merged by a person, by a standing captain order
("every hide is a person's decision", `hide_batch.py:416`). Under the new rule that order and this one disagree.
Auto-merge would be a change in H-DevOps and platform-data-processing, not in hydra.
