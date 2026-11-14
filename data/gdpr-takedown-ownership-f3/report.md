# Who took profiles down, and did they own them

Measured 2026-11-13 18:40Z to 19:10Z, read-only. Window: 90 days (2026-08-15 to 2026-11-13). Merges are excluded.
Nothing in any datastore was changed and nothing was restored.

Rows: `audit.csv` (one per profile, ids only; a requester is a 10-hex hash of the address). Rebuild:
`tools/build_audit.py`. The copy with names and addresses stays out of git.

## Answer to "are we being gamed"

The records cannot answer it for 193 of the 253 profiles, because nothing was recorded that ties the requester to
the profile. That is the finding. I found no row that proves an impostor, and one row where the requester is not
the account that holds the claim.

| Basis on record for the removal | Profiles | What it means |
|---|---|---|
| Owner verified | 60 | The requester's account or address holds the processed claim on that profile |
| Name only | 61 | The requester's name or address resembles the profile's name. No claim. Anyone with that name passes |
| Legal or DMCA request, no approver recorded | 45 | A legal threat or DMCA notice named the profile. Nobody is recorded as having approved it |
| Request on file, no tie to the profile | 35 | A request exists; the name does not match and there is no claim |
| No request on record at all | 52 | An admin soft-delete with no request reference. Who asked is not in any record I read |
| **Total** | **253** | |

Last 30 days only (from 2026-10-14): 132 removed; 47 owner verified, 39 name only, 24 legal or DMCA with no approver,
10 no tie, 12 no request.

## How they were removed

| Path | Profiles | Reversible | Actor on record |
|---|---|---|---|
| Admin soft-delete (`DELETE /admin/profile/<id>`) only | 148 | Not by any tested step (see Restore) | Yes |
| Hide list only (two reviewed PRs, a person merges) | 76 | Yes, remove the id | The PR |
| Both | 12 | Hide: yes. Delete: as above | Yes |
| Gone from the public site, no delete row and not on the hide list | 17 | Unknown | No |

All 160 soft-deleted profiles are still deleted. 1 of the 160 delete rows carries a request reference.

Soft-deletes by caller, all requested under one staff name except the last line:

| Caller | Profiles |
|---|---|
| Ops agent on a staff Slack ask (`agent-hydra-main`, via muso-cli or clio) | 68 |
| The same staff login directly, muso-cli or clio (no agent recorded) | 63 |
| `seo-removals-c2`, a firstmate lane with its own admin login | 29 |

## Every path that can hide or delete a profile

"Read" means I read the code in hydra. "Data" means I saw its rows in core and did not read its code.

| # | Path | Who can start it | What had to show the profile was theirs | Rate limit | Basis | After this branch |
|---|---|---|---|---|---|---|
| 1 | Erasure request, then the hide list (`hide-batch`, 4 runs a day, two PRs, a person merges) | Anyone who writes to Intercom, support@, notices@ or legal@ | A processed claim, or a verified sender on the profile's own site. A name match also passed until 2026-11-12 | None | Read | The guard |
| 2 | Legal threat, hide first (`hide-batch --include-legal`) | Anyone who sends a legal threat; a person runs the command | Nothing. Big-name pages were excluded | None | Read | Guarded: hidden only for the account that holds the claim, otherwise held with the ask |
| 3 | DMCA notice in the register | Anyone who sends one | A processed claim, else a person's review | None | Read | The guard reads the claim again |
| 4 | Track or album in the register | As 1 to 3 | Its one artist's profile passes 1 to 3 | None | Read | The guard, on the artist's profile |
| 5 | Staff Slack ask, ops agent calls `DELETE /admin/profile/<id>` | Staff on the operations Slack account | Nothing | None found on this route | Read, and 68 rows in data | Not changed here. https://github.com/Muso-AI/hydra/pull/1951 refuses it, open |
| 6 | Staff login calls the same route through muso-cli or clio | Anyone with that admin login | Nothing | None | Data, 63 rows | https://github.com/Muso-AI/hydra/pull/1951 covers the muso CLI on node-8 only |
| 7 | A firstmate lane with its own admin login (`seo-removals-c2`) | Whoever dispatches the lane | Nothing | None: 29 in 6 minutes | Data, 29 rows | Not covered |
| 8 | Ops-intake router (`scripts/ops_intake`) | Staff on Slack | It answers a hide ask by naming path 1; profile delete is granted to nobody; its write execution is off | Its own caps | Read in part | Unchanged |
| 9 | Caroline | A customer in Intercom | She holds no hide or delete write (`policies/caroline-billing-and-hide.json`, pinned by a test); she files to the register | n/a | Read | Unchanged |
| 10 | A hand-written PR adding an id to `HIDDEN_ENTITY_IDS` or `LEGAL_HIDDEN_ENTITY_IDS` | Anyone with write access to H-DevOps or platform-data-processing | Whatever its reviewer asks | None | Not read | Not covered |
| 11 | Core admin route with a person's own token, and the admin console | Any admin account | Not read | Not read | Not read | Not covered |
| 12 | Profile merge (`profile_merges`) | Staff request | The loser disappears into the survivor. Excluded from this audit by Aaron ("merging is fine"); one check kept, below | Not read | Data | Unchanged |
| 13 | capture-404 raw-data deletion (industry-data-processing) | A pipeline job | Nothing | Not read | Not read | Fix is industry-data-processing #1846 |
| 14 | `public_takedown_suppression` table in core | Not read | Not read | Not read | Schema seen only | Not covered |
| 15 | Unknown: 17 profiles gone from the public site with no delete row and no hide-list entry | Not on record | Not on record | Not on record | Data | Not covered |

None of the 15 had a per-requester or per-day limit before this branch. Path 1 to 4 now have one.

## Gaming signs

**Claimed by someone else: 1.** `d5a2d6b1-e653-45df-bf84-d7db5593df08` (2 credits). A processed claim has been held
since 2026-09-26 by one free-mail address. Three requests (register 25, 51, 396: two legal threats and one erasure)
came from a different free-mail address whose name matches the profile. It was hidden on 2026-11-02 and soft-deleted
on 2026-11-06 by the ops agent. Either one person uses two addresses, or one of the two is not the artist. Not
resolved.

**Claimed profiles removed with no proof from the claim holder: 13** (the row above plus 12 soft-deletes with no
request on record). One is a paid profile, `5c4dfece-2cd2-415e-a220-83504f3ac11f`, deleted 2026-09-19. Ids are in
`audit.csv`, flag `CLAIMED_REMOVED_WITHOUT_OWNER_PROOF`.

**Free-mail requester, well-known profile (popularity 40+), no claim: 7.** Flag `FREEMAIL_VS_KNOWN_ARTIST`. Four
were soft-deleted, three are on the hide list.

**One requester, more than 3 profiles: 5 requesters, 22 profiles.**

| Requester | Profiles | Distinct names | Basis | Removed how |
|---|---|---|---|---|
| 25b55715f1 | 5 | 4 | legal or DMCA, no approver | soft-delete |
| e7fd73b4c2 | 4 | 4 | 3 legal or DMCA, 1 owner verified | soft-delete |
| a403e255b5 | 4 | 4 | name only | soft-delete, 3 also hidden |
| 8b448f3070 | 4 | 4 | 2 name only, 1 owner, 1 no tie | soft-delete, 1 hidden |
| 132487a4be | 5 | 2 | name only | not hidden: sat in a hide PR that was replaced |

Some of these read as one person's spelling variants and labels. I did not verify that for any of them.

**Bursts (one caller, one day, more than 3 soft-deletes): 13 caller-days, 104 profiles.**

- 2026-10-02: 29 by `seo-removals-c2` in 6 minutes. 14 have no request on record, 4 were claimed, 3 owner verified.
- The other 12 days are the staff login: 12 on 11-06, 10 on 10-14, 8 on 09-30, 8 on 11-07, and eight days of 4 or 5.
- Hide list: 52 profiles carry a hidden date of 2026-11-06. That date is when the register first read them as
  hidden, not when they were merged, so it is not a burst by itself. 35 of the 52 are owner verified, 16 name only.

**Paid profiles removed: 4.** Two are owner verified hides. `5c4dfece` is above. `2547286b` was soft-deleted
2026-10-06 on a name match.

**Merges (the one check kept):** 8 of 707 merges of a claimed profile joined profiles claimed by two different
accounts; 3 touch a paid profile. All are near-identical names. Listed in the work directory, not undone.

## Restore step, per group (nothing restored)

| Group | Profiles | Step |
|---|---|---|
| Hide list | 88 | Remove the id from `HIDDEN_ENTITY_IDS` (H-DevOps) and `LEGAL_HIDDEN_ENTITY_IDS` (platform-data-processing), one PR each |
| Admin soft-delete | 160 | The only written procedure (`skills-all/muso-clio/references/operations/entity_deletion.md`, Entity Restoration) un-deletes the muso raw profile and re-syncs. It was written for the old Mongo catalog and I did not test it. Hydra #1951 measured 23 profiles and 717 credits on these tombstones with no inverse. Treat as not reversible until one profile is restored on a test copy |
| Gone, no actor | 17 | Find what deleted them first. No delete row exists in 90 days |

Per-profile restore step: column `undo` in `audit.csv`.

## Freeze lever (not pulled)

| Lever | Stops | Also stops | Undo |
|---|---|---|---|
| Do not merge https://github.com/Muso-AI/H-DevOps/pull/5286 and its platform-data-processing twin | Every new hide | The 7 it adds, all owner verified, with statutory dates running | Merge it |
| `systemctl stop gdpr-hide-batch.timer` on node-8 | New hide PRs being prepared | Same as above | `systemctl start gdpr-hide-batch.timer` |
| `touch /etc/hydra/gdpr-pipeline.disabled` | The above | Intake, identity decisions and every statutory letter. Too broad | Remove the file |
| Merge and deploy https://github.com/Muso-AI/hydra/pull/1951 | The soft-delete for every agent and muso-cli caller on node-8 | Nothing else | Revert |
| Remove the admin role from the `seo-removals-c2` login (core) | That lane's direct deletes | Whatever else the lane does | Re-grant |

Not covered by any lever in hydra: a person calling the core admin route with their own token, and the admin
console. That needs a refusal in core-backend, which this lane cannot edit.

The narrow freeze is the guard in this branch: it leaves owner-verified hides running and holds the rest.

## The claiming process

An erasure requester with no claim is told to claim the profile. Artist claims are not being decided:

- 1,968 artist claims pending, 386 older than 30 days, oldest filed 2026-09-18. About 70 new a day.
- The last artist claim decided after a wait was 2026-11-12 01:04Z. 85 were decided in the last 7 days.
- The daily "processed" count (144 to 233) is professional claims approved in under 5 minutes: 1,232 of 1,343 in
  7 days. Those are not reviewed claims.

So "claim it, then we hide it" cannot finish inside a statutory month for an artist today.

### Can an instant claim take over an existing profile (measured 20:26Z to 20:40Z)

In 30 days, 5,214 claims with reason `created by user` were processed within 5 seconds of being filed, with no
verification links. 4,432 of them are in the catalog view; the other 782 are not and were not measured.

| Profile the instant claim sits on | Claims |
|---|---|
| Created within 5 seconds of the claim (the account's own new profile) | 4,429 |
| Created within the hour | 1 |
| More than 3 years old, one muso source, 0 credits | 2 |

Direct route: not seen. No instant claim landed on a profile that came from a streaming service.

Indirect route: seen. 2 of those new profiles later became the survivor of 4 merges, run by a staff login 5 days
or more after the claim. One now carries 3 Tidal sources and 295 credits (`b98492ee-1510-44a7-94e6-a66af6127b30`).
An unverified claim then covers an artist's catalog page, and the hide pipeline reads it as a processed claim
(`sources.processed_claims` counts every processed claim alike).

What the guard does about it: a claim made with no verification counts as ownership only while the profile holds
nothing but the one source that account created. Once anything is merged in, the requester is asked to verify.

What the claiming process must change (core-backend, not this lane): a merge into a profile whose only claim is
unverified should not carry that claim over the merged-in sources without a verification step.

## The rule

A profile is hidden only when the requester owns it, shown one of two ways:

1. the requesting account holds a processed claim on the profile, and that claim was reviewed (filed against an
   existing profile, with a verification link) or sits on the one profile that account itself created; or
2. a verified sender writes from the profile's own website. Both halves are read again when the hide is
   prepared: the profile's website must still be the sender's host, and the request is decided again so the
   sender's verification is read at that moment (added 2026-11-14 after QA review of the PR).

A matching name is not ownership. A legal or takedown request is not ownership. A passport is not asked for: it
shows who the person is, not that the profile is theirs (captain, 2026-11-12). A requester who cannot show either
is asked to claim the profile or send the owner's written authorisation.

On top of ownership: 3 profiles per requester and 20 across the register in any 24 hours. Past that the page is
held, #cs_priority is told once, and it is offered again on the next run. Every admit and every hold is a row on
the request. The hide stays the reversible list entry.

What this rule does not contain: the spec's second route, a legal takedown approved by someone with authority.
Aaron's rule at about 20:00Z ("never should we ever use a person to evaluate this") rules out a person approving,
so I did not build it. A legal request is held until ownership is shown. This reverses the 2026-10-23 rule (legal
threat on a small page: hide first, identity after) and needs Aaron's word either way.

## What was built (hydra, one branch, not pushed)

- `scripts/gdpr_pipeline/hide_guard.py`: the guard, between the hide plan and the hide PRs.
- `Run.decide_row` weighs the requester's claim with the same rule, so an unproven claim is asked, not passed.
- `tests/test_gdpr_hide_guard.py`, wired into PR Validation. The two the contract names:
  `test_a_non_owner_request_is_refused_and_the_owner_is_prepared` and `test_a_burst_is_refused_and_paged`.
- The three existing GDPR suites and the Caroline billing-and-hide suite still pass with it.
- 12 hand-made faults (a cap removed, the account check removed, a failed read ignored, the identity-step call
  removed, and so on), run against the code as first written. 11 failed a test. The twelfth did not: a profile
  missing from the claim answer could be read as "no claim" in the identity step. I added the test for it and that
  fault now fails too.
- Not run to the end: `scripts/tests/test_ci_test_discovery.py` (stopped at 400 s). It scans only
  `python3 scripts/tests/*.py` steps, and the new step is `python3 -m unittest`, so it does not read this file.

Run against a copy of the live register on node-8 at 21:56Z, with the PR and Slack writes replaced by recorders
(`tools/guard_scratch_run.py`); the live register was read and not written:

| Open pages that had passed on a claim | 9 |
|---|---|
| Admitted: reviewed claim | 3 (2 profiles, 1 track) |
| Admitted: the account's own profile | 4 |
| Now asked for evidence of authority (register 469) | 1 |
| Now with a person, not asked (register 369, an album) | 1 |
| Held by a cap, alerts posted | 0, 0 |

Register 469 is profile `91f23bc0`: paid, popularity 87, 1,917 credits, 57 sources. Its claim is from 2023, has no
verification link, and belongs to the requester. It is one of the 7 ids in
https://github.com/Muso-AI/H-DevOps/pull/5286. Once this ships the next run replaces that PR with one that leaves
it out.

## What is still open

- **Fable has not reviewed this.** Aaron asked for Fable on the takedown process. This lane has no way to ask
  Fable; firstmate has to route the design and the diff.
- **"No path can hide someone else's profile" is not met.** Paths 1 to 4 are guarded. Path 5 and part of 6 wait on
  https://github.com/Muso-AI/hydra/pull/1951 (no file in common with this branch). Paths 7, 10, 11 and 14 need a
  refusal in core-backend or branch protection, outside hydra. I read no core-backend code.
- **Legal hide-first.** 14 open requests (27 pages) hold a `LEGAL_HIDE_FIRST` page. After this branch a legal
  threat is hidden only when the requesting account holds the profile's claim (path A, the same rule as any owner
  request); every other legal page is held and its hold names the ask - the requester's claim, or the owner's
  written authorisation (a link, or a label/management document). No ask copy is released for a legal-threat
  requester, so the reply to the threat is still the captain's.
- **Tracks and albums still end at a person.** `identity.decide_item` gives no ask, because the approved ask copy
  is about a profile. Register 369 moved from a pass to that queue under this change. An ask for an item needs
  new customer copy through the copy gate.
- **One profile already hidden on an unproven claim.** `2be757a6` (register 369's artist) is on the hide list on an
  instant claim the rule does not count: the profile is not the single-source one that account created. I did not
  read which sources it holds. Listed, not restored.
- **A person still merges the two hide PRs** (standing captain order), which Aaron's 20:00Z rule contradicts.
- **The 160 soft-deletes** have no tested restore.
- **Artist claims are not being decided**, so "claim it, then we hide it" cannot finish inside a statutory month.

## Not measured

- Slack and Intercom threads behind the 52 soft-deletes with no request on record.
- core-backend: the delete route's own checks and the admin console. I read hydra only.
- Whether the 61 name-only requesters are the artists. A name match was all that was recorded.
- Removals before 2026-08-15.
- capture-404 raw-data deletion (industry-data-processing #1846): a different store, not in this audit.
