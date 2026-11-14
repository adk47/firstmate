# GDPR overdue drive g2 (2026-11-13)

Measured on node-8 (deployed `5e2765d4`) with the pipeline's own clock. The classification is
`classify.json`, produced by `tools/classify.py` (read-only; counts and register numbers only, and the send
ledger's free-text `held` detail cut to its kind and state, since that text can name a target address).

## The clock, before and after

| read at (UTC) | open | past date | due in 7 d | no first message after 48 h |
|---|---|---|---|---|
| 16:34 | 308 | 154 | 34 | 65 |
| 17:17 | 308 | 154 | 34 | 65 |
| 17:31 | 308 | 154 | 34 | 65 |

The 17:31Z row is after the 17:27Z tick (ladder: 73 owed, 7 sent, 64 refused, 2 held; the 7 went to
people already written to).

Nothing in this change has moved the clock yet. The fix is a code change: it sends nothing until it is
merged and deployed, the reviewer host has the new rubric, and the reviewer approves the letters.

## 1. Why "no first message" read 3, then 66

It did not rise. The clock line prints that list in two parts: the requests not already named in the
past-date / due-soon list, then "(and N of those named above)". "3" was the first part only (#86, #246,
#483 at 12:07Z); "66" was the whole list (3 + 63).

Whole-list totals from the `gdpr-dsar-clock` journal: 168 (11-12 22:07Z) -> 143 (04:07) -> 118 (05:07)
-> 93 (06:07) -> 75 (07:07) -> 72 (10:07) -> 68 (12:07) -> 66 (15:07) -> 64 (16:07) -> 65 (16:34).
The #1803 deploy added none.

The sender ran every hour and every tick since 03:33Z exited 0. The copy gate is not skipping: its holds
are `copy_review_pending` (12 at 16:31Z), and `gate.py pending-age` on node-8 at 17:21Z read
`pending 0, held 0, stale false`, so the reviewer round is keeping up.

What holds the 65 (at 17:17Z):

| n | cause | requests |
|---|---|---|
| 38 | Deletion request written to notices@ / legal@. The only route is a new mail thread from support@. The ladder letter was approved as its body alone, and `send.deliver` then refused it because the new thread's opening line and subject were not what was reviewed. **Fixed by this change.** | #15 #16 #20 #21 #22 #23 #27 #40 #42 #44 #46 #47 #48 #49 #50 #51 #52 #56 #57 #59 #62 #63 #65 #67 #68 #69 #70 #71 #74 #76 #77 #79 #80 #81 #82 #86 #242 #246 |
| 1 | Same route, letter still waiting for review (also covered by the fix) | #507 |
| 13 | No thread and no address on file: there is nowhere to write | #10 #11 #138 #151-#160 |
| 1 | notices@ thread, no address on file | #24 |
| 6 | support@ row with an address and no thread. A new thread is allowed for notices@ / legal@ only | #139 #213 #214 #215 #236 #237 |
| 5 | Inside the last 3 days before the date with no message so far. By design nothing is owed until the date passes (an acknowledgement would state a date we cannot promise); the late update goes when the date passes, between tonight and 11-15 | #119 #130 #222 #223 #224 |
| 1 | An interim confirmation is `unknown` ("POST NOT VERIFIED"): a letter may be out, so code will not retry | #468 |

On the whole register that refusal stood on 42 open deletion requests (26 notices, 16 legal), all with an
address, 38 distinct addresses (one person has 4 requests, one has 2). Three of the 42 (#17 #26 #508)
already have their final response and are owed nothing, and #41 already had a first message, which is why
38 of the 42 are in the no-first list.

**This change cannot take the no-first count to 0.** At best it releases 39 letters (38 + #507), leaving
26. Five of those clear by themselves when their date passes. The other 21 (13 + 1 with nowhere to write,
6 support@ rows, #468) need decisions 5, 6 and 7 at the end of this report.

## The fix (commit on `fm/gdpr-overdue-drive-g2`)

- The reviewer is shown the letter as it goes on the wire (`send.reviewed_form`): opening line + body,
  with the subject. The author step and the send step ask about the same pair. The blanket refusal is
  removed. Every byte still comes from `copy.py`; both the line and the subject already have rulings
  (`legal-finalize-fable-k1/2026-11-04-new-thread-lead`, `gdpr-support-from-1104`).
- Rubric rule 8 said "no email address". It now names that one line and subject as allowed, for deletion
  requests only. Without this a reviewer following the rubric refuses the letter for naming
  `notices@muso.ai`.
- One customer message per person per UTC day (`store.person_contacted_on`). There was no such guard. A
  person with several requests gets one letter a day until each request has its own; the Art. 15 answer
  (`Run.access_deliver`) is held by the same rule.

**After merge and deploy** (not done here):
1. Run `scripts/outbound_copy/install-reviewer-host.sh` on the reviewer host (ak47). Until then the two
   hosts hold different `gdpr` rubrics and no `gdpr` letter is reviewed.
2. Every unsent `gdpr` body is reviewed again under the new rubric (the verdict is bound to the rubric's
   sha256). About 12 held letters plus the 42 new ones; the round takes 60 per pass.
3. The reviewer may still refuse the new-thread letter. That is a hold, and the reviewer's note says why.

## 2. The 154 past date, by what is owed

| n | owed | wait is on | can code do it today |
|---|---|---|---|
| 51 | Erasure. The page is already off the site (`GONE`), so nothing is left to hide. The final letter is owed | Muso | No. No approved wording says "this page was already gone" |
| 37 | Erasure. A page link (23) or a claim / proof of authority (14) is needed, and a message saying so was sent | requester | Nothing more to send; no approved "we could not confirm, the request is closed" letter exists, so these stay on the clock |
| 29 | Erasure. A link (16), claim or authority (8) or authority (5) is needed and nothing has reached the person | Muso | 25 of them are notices@ / legal@ rows the fix reaches; the rest have no route (#138 #213 #214) or need a person (#468) |
| 12 | Erasure. Identity not decided: 8 are marked for a person's review (`JAN_REVIEW`: #1 #15 #146 #152 #155 #176 #211 #321), 4 support@ rows read `UNKNOWN` (#154 #156 #158 #160) | Muso | No |
| 11 | Access. The copy of their data | Muso | No. `access.standing_gaps` lists 11 gaps: 9 systems not covered, no approved Art. 15(1) text, columns not reviewed for other people's data |
| 11 | Erasure. Hidden, or in the hide batch. The final confirmation is owed | Muso | Partly, see below |
| 3 | Access. The account is not established | Muso | No. #220 got a status update at 05:34Z today, but no ask exists for an access request (asks are approved for deletion only); #236 #237 have no route |

Register numbers for every row: `classify.json` (`past_by_what_is_owed`).

The 11 awaiting a final confirmation:
- #334 #369 #469: identity verified (`PASS_A`), pages not hidden yet. **Their hide PRs were closed
  unmerged at 15:38Z today**, see the next section.
- #205 #350 (Intercom) and #16 #21 #22 #51 (new thread): already hidden, but the search check cannot be
  measured (the name returns a full autocomplete page of 30, or the row has no page name), so the tick
  drops the row every hour ("not confirmable here", 22 rows in the 16:31Z tick).
- #24 #139: already hidden, no route to the person, and the same unmeasurable search check.

### The live hide batch was closed by a run on test data (found while checking this report)

At 12:22Z node-8's `gdpr-hide-batch` opened https://github.com/Muso-AI/H-DevOps/pull/5261 and
https://github.com/Muso-AI/platform-data-processing/pull/2587 with six real ids (#469, due 2026-10-24,
among them). The reviewer gave 5261 a GO at 14:01Z.

At 15:38Z something ran the hide-batch code with a register that is not node-8's:
- it opened https://github.com/Muso-AI/platform-data-processing/pull/2588, which adds one id,
  `0d898512-1111-2222-3333-444455556666`. That is `UUID_A` in `tests/test_ops_intake.py`. The PR body
  says "Filed by the ops intake ask `ask-1` (scripts/ops_intake/hide.py)"; that file is not on `main`,
  it is in https://github.com/Muso-AI/hydra/pull/1837;
- it closed 5261 ("nothing in this PR is still waiting") and 2587 ("superseded by 2588").

Node-8's journal has no hide-batch run at that time and its register has no event after 12:22:59Z, so the
run was elsewhere. A branch `fm/gdpr-pipeline-g1-refresh` was pushed at 15:38:42Z; that it came from a
test run on that lane is my inference, not something I measured.

State now: none of the six ids is on H-DevOps `main`, no H-DevOps hide PR is open, and 2588 (a test id
against the production sitemap list) is open. I changed nothing. Node-8's next `gdpr-hide-batch`
(18:20Z) should open a new pair with the real set and close 2588 as superseded, but the 14:01Z GO does
not carry over, and the same thing will happen again each time that code runs against the real
repositories.

By route: 101 Intercom, 35 new mail thread, 11 no thread and no address, 6 support@ with an address and
no thread, 1 notices@ with no address.

Nothing was executed by hand: every mechanical step that exists (asks, confirmations, ladder letters, hide
batch) already runs in the hourly tick, and a manual run would be the same code on the same rows.

## 3. Closing

44 open statutory rows already have their final response on the ledger. The ladder counts them as
closed and the clock does not count them (352 open statutory rows, 308 on the clock). Their `status`
column still says `open`: it is only ever closed from the markdown register (`run.intake_register`).
Seven of them (#3 #6 #137 #140 #164 #204 #346) had their confirmation sent on 11-08. No count changes.

## Decisions that are not mine

Each of these needs words nobody has approved, or a person:

1. **Final letter for a page already off the site** (51 past rows). The largest group. Needs approved
   wording.
2. **Art. 15 answer** (11 past, more inside the window). Needs the 11 manifest gaps closed, including the
   Art. 15(1) text.
3. **Closing a request the requester never completed** (37 past rows, wait on the requester). Needs an
   approved second ask and "we could not confirm" letter, or the clock keeps counting them.
4. **Search check unmeasurable** (6 rows). Whether the final confirmation may go on the page and sitemap
   lines alone when the search cannot be measured.
5. **support@ rows with an address and no thread** (6 rows). Whether a new thread may be opened for them;
   the lead ruling names notices@ and legal@ only.
6. **14 rows with nowhere to write** (#10 #11 #24 #138 #151-#160; 12 of them past date). The address has
   to be recovered from the original message; the support@ ledger stores a truncated hash of the sender.
7. **#468** (1,014 days). A person reads the conversation and resolves the `unknown` send
   (`gdpr-pipeline.py resolve --row ... --kind confirm-interim`). Its ask is also refused: the identity
   sentence "as it appears on your ID" was barred on 2026-11-12 and has no replacement.
8. **Hide batch PRs** (3 past rows, 6 ids). A person merges the pair node-8 opens next, and whoever owns
   the ops-intake hide lane stops its runs reaching the real repositories.

## Hold on erasure execution (firstmate inbox 001, 2026-11-13 18:47Z)

The instruction: execute no erasure, hide or delete unless the requester is the verified claimant of that
exact profile or has supplied identification matching the profile's person; keep sending first replies and
identity asks; everything else waits on the requester.

This lane has executed none and its commits execute none. What the automation is doing, measured at
18:48Z-19:00Z on node-8 and the core replica:

**An open hide batch is waiting for a person's merge.** `gdpr-hide-batch` ran at 18:20Z and opened
https://github.com/Muso-AI/H-DevOps/pull/5286 and
https://github.com/Muso-AI/platform-data-processing/pull/2590 with 7 ids (it closed the test-data PR 2588).
Every id is there on the same ground: the requesting account holds a processed claim on that exact page.
What that claim is differs:

| request | claim | account resolved by |
|---|---|---|
| #469 | made 2023, no verification links | signed-in Intercom id |
| #465 | March 2026, reason `backfill auto-profile`, no verification links | signed-in Intercom id |
| #442 | carries verification links, took 12 days to process | signed-in Intercom id |
| #60 (DMCA, mail to notices@) | carries verification links, processed the day after it was made, 2.6 h before the request | the mail's sender address equals one account's sign-in address |
| #400 | reason `created by user`, no links, processed the instant it was made, account created the same second, 20 min AFTER the request | Intercom contact's address equals one account's sign-in address |
| #466 | same shape, 7 min before the request | signed-in Intercom id |
| #504 | same shape, 3 min before the request | signed-in Intercom id |

Two more with a claim are prepared in neither repository (track / album, blocked on a missing test set):
#334 (claim with links) and #369 (the `created by user` shape, 30 h before the request).

On the replica, of 5,798 processed claims made in the last 30 days, 5,226 are `created by user`, carry no
verification links and were processed in the instant they were made; the 572 others carry links (one does
not) and were not instant. **I have not measured what a `created by user` claim is on**: a profile the
account made for itself at sign-up, or a catalog profile attached with no check. If it can be the second,
a claim made minutes before the request proves nothing, and #400 #466 #504 are the pattern the hold is
about. That is the one fact to establish before anybody merges 5286 / 2590.

**No hide runs on anything weaker than a claim today.** No open row carries a name-match or domain pass.
14 legal-threat rows are hide-eligible with no identity at all (hide first, identity after), but only
through `hide-batch --include-legal`, which the timer does not pass. Nobody should run it during the hold.
The domain path (`PASS_D`: a verified sender whose host is the page's own website) is still in code and
would enter the batch; it has 0 rows.

**The identity ask.** Rows with no claim already get an ask instead of a hide (37 open deletion requests
read `ASK_IDENTITY`, 2 `ASK_AUTH`; 26 were asked). 13 have not been asked (#20 #42 #48 #59 #65 #67 #70 #71
#80 #81 #468 #503 #504): the older identity-ask sentence is refused since 2026-11-12, so their ask is the
reviewed ladder letter, and for the ten on notices@ / legal@ that letter is the one the fix on this branch
releases.

**Identification is not a path that exists.** No approved copy asks for an identity document and no code
accepts one (ruling of 2026-11-12: no copy asks for one, and a name match ties nobody to a page). The claim
is the only ground a hide runs on. Accepting identification would need new wording and a ruling.

## Ruling on claims (firstmate inbox 002, 2026-11-13 20:23Z)

The ruling: an instant `created by user` claim with no verification links does not make the requester the
page's owner for a hide. #400 #466 #504 #469 #465 come out of the hide batch and get an ID-or-link ask;
#60 and #442 stay.

**Done.**

| what | state at 21:05Z |
|---|---|
| The 7-id pair | https://github.com/Muso-AI/H-DevOps/pull/5286 and https://github.com/Muso-AI/platform-data-processing/pull/2590 closed unmerged at 20:47Z |
| The 2-id pair (#60 `a62c3c72`, #442 `4565420d`) | https://github.com/Muso-AI/H-DevOps/pull/5297 (checks still queued) and https://github.com/Muso-AI/platform-data-processing/pull/2592 (18 of 18 checks passed, needs a review). Each PR's diff adds exactly those two ids. Cut by hand with the pipeline's own `open_prs`, because node-8's deployed code still counts all seven |
| `gdpr-hide-batch.timer` on node-8 | **stopped at 20:43Z, still enabled.** Its 00:20Z run would have re-opened the 7-id pair. Revert: `systemctl start gdpr-hide-batch.timer`. A deploy starts it again by itself |
| The rule in code | on this branch, not deployed: a claim ties a requester to a page only with a verification link on it and `updatedat > createdat` (`sources.processed_claims` + `sources.link_matches_profile`). Read against the replica through node-8: of the 7 claimed pages, #60 and #442 have evidence and the other five do not, and the set of claim holders is the same as the deployed read returns |
| Verdicts already on file | every page verdict is stamped with the rules it was decided under. An older pass is not hide-eligible, the tick decides the row again on its next run, and while one is on file `hide-batch` touches no PR (an empty batch would close the live pair) |

**Order of operations after merge.** The deploy starts the timer. The first `hide-batch` after it does
nothing until the hourly tick has decided the seven rows again; after that its set is #60 + #442, the same
as the open pair, and it leaves the pair alone.

**Not done: the ask as ruled. It needs words that do not exist.**

- No approved wording asks for a verification link on a claim, and the `gdpr` rubric's rule 2 refuses any
  letter that asks for an identity document (ruling of 2026-11-12: "do not collect passports"). The ruling's
  option (b), ID matching the profile's person, contradicts that one.
- The nearest approved letter is `claim_or_authority`: "claim the page in the Muso app, or send a document
  from the artist's label or management ... You do not need to send a passport". All five have already
  claimed the page, so its first half is the wrong instruction for them.
- What the five have on their thread today, and what the code on this branch would send next once deployed:

| request | due | last message from us | next from the ladder |
|---|---|---|---|
| #469 | 2026-10-24 (past) | 11-13 06:35Z late update saying **nothing is needed from them** (`late_none_no_date`), next contact promised in 14 days | `late_claim_or_authority`, near 11-27 |
| #400 | 2026-12-06 | 11-09 the older ask (its other page is gone) | `status_claim_or_authority` at the halfway point, 11-21 |
| #465 | 2026-12-11 | 11-11 the older identity ask (wording since barred) | status update at halfway, 11-26 |
| #466 | 2026-12-11 | 11-11 the older identity ask (wording since barred) | status update at halfway, 11-26 |
| #504 | 2026-12-13 | 11-13 06:35Z `ack_claim_or_authority` | status update at halfway, 11-28 |

  So no letter reaches any of the five promptly, and #469 was told this morning that nothing is needed.

- **The clock note.** The register has no field that pauses or annotates the statutory date. After deploy
  the reason is on each page verdict ("the requesting account's processed claim on this page carries no
  verification links ... ruling 2026-11-13") and the ladder state becomes `identity_check`; the due date does
  not move. Whether an identity request under Art. 12(6) moves the date is a legal position, and I did not
  write one into the register.

**Decisions needed.**

1. The wording of the ask: a new `need` ("add a link to your artist page or socials to your claim, or send a
   label / management document"), or the existing `claim_or_authority` letter as it stands. New wording needs
   its ruling, a rubric rule 2 line that allows it, and the reviewer's verdict.
2. Whether an identity document may be asked for or accepted at all (2026-11-12 says no, 2026-11-13 option
   (b) says yes).
3. Whether a letter goes at once when a ruling changes what a request needs (today the ladder waits for
   its next scheduled message), and whether the statutory date moves while the ask is open.
4. A reviewer other than `adk47` for the two PRs (the QA identity authored them, so its approval is refused).

## The ownership ask (firstmate inbox 003, 2026-11-13)

The rulings: new wording that asks for a matching link or a label / management document; no letter asks for an
identity document; send at once to #400 #465 #466 #469 #504 when the verdict lands and correct #469's "nothing
needed"; note on each row when the ask went; move no statutory date.

**Nothing has been sent.** The ask is built, tested and reviewed in a scratch gate. The pipeline on node-8 is the
only sender, and it runs the deployed code, so the five letters go after this branch is merged and deployed.

| ruled | state |
|---|---|
| wording | Block `need_claim_evidence` and three variants (first message, update before the date, update past the date) in `policies/gdpr-dsar-copy.json` v4 |
| rubric rule 2 line | Added: a link to their own artist page or an official social account that matches the profile, or a label / management document; never an identity document |
| AI verdict | 3 approve of 3 from the reviewer model under the amended rubric, in a scratch mirror with a throwaway key (`copy-review-round5.json`). That is a rehearsal: the verdict a send needs is the one the reviewer host signs on the body node-8 writes |
| send at once | `dsar.owed` sends the ask without waiting for the halfway point, the quiet week or a promised next contact; once per request; still one message per person per UTC day |
| #469 | Gets the past-date update with the ask; its body does not say nothing is needed |
| register note | `ownership_ask_at` on the row, the time the ask went, plus an event on the row's trail |
| statutory dates | Untouched; a test holds `due_at`, `received_at` and the extension columns equal before and after |

Tests: `tests.test_gdpr_pipeline` + `tests.test_gdpr_dsar` 657 OK (8 new); ten mutations, nine fail a test and
the tenth is a redundant condition.

### One change from the ruled wording

The ruling says "add a link to your claim". The letter says "reply here with a link". Core has no route that adds
a link to a claim once it is processed: the only API that writes `verificationLinks` is the challenge-code proof
(`core-backend src/apis/team/v4/claimProof.js`), which refuses any claim that is not pending and answers 503 while
no approval writer is live. I read core by search, not exhaustively. Telling five people to do something the
product does not offer would have them write back that they cannot.

### What happens to the reply: nothing, yet

No code reads a link or a document sent in reply. The hide rule passes only on `claiming.verificationlinks`, which
a reply does not change, so a reply never hides a page by itself. Until a reader exists, each reply is a person's
to read. Core's own proof flow counts a surface only when the catalog already attributes it to the artist ("a
fraudster can post on their own fake IG"); a link the requester names proves little by itself.

### Order after merge

1. Deploy. It restarts `gdpr-hide-batch.timer`; the batch does nothing while old-rules passes are on file.
2. Run `scripts/outbound_copy/install-reviewer-host.sh` on ak47. The `gdpr` rubric changed (rules 2 and 8); until
   the hosts agree, no `gdpr` letter is reviewed and nothing in the ladder goes.
3. The next hourly tick decides the five again (need: ownership ask) and writes their bodies; the reviewer round
   (every 15 min) signs; the tick after that sends. About one to two hours after step 2.

## State at 22:29Z: the hide timer came back with a deploy, and was stopped again

- https://github.com/Muso-AI/H-DevOps/pull/5297 and
  https://github.com/Muso-AI/platform-data-processing/pull/2592 (#60 and #442 only) were merged at 21:56Z.
- A deploy at 21:36Z (`7210fe013`, https://github.com/Muso-AI/hydra/pull/1953) restarted
  `gdpr-hide-batch.timer`. That deploy does not carry the claim rule (this branch is not pushed).
- A dry run of node-8's deployed `hide-batch` at 22:27Z planned a new pair for #469 #400 #465 #466 #504:
  the five pages the 20:23Z ruling took out. Its 00:20Z run would have opened that pair.
- The timer was stopped again at 22:29:14Z. No PR was opened. Revert: `systemctl start gdpr-hide-batch.timer`.
- **The stop does not last.** Every deploy starts the timer (`scripts/install-aux-units.sh`), and the next
  scheduled one is 05:38Z, so the 06:20Z run opens the five-id pair unless this branch is deployed first.
  A pair opened that way hides nothing by itself (a person merges), but it must not be merged.
- Clock at 22:26Z: 308 open, 154 past date, 36 due within 7 days, 65 with no first message. Unchanged,
  because nothing on this branch is deployed.

## QA review of hydra #1963 (2026-11-14): what changed and what did not

Two findings, both on head 9500b0557.

**A claim passed on any filled link field.** The rule (`sources.processed_claims` + `sources.link_matches_profile`) now needs a link to a page (a
page-shaped link at that round; the ruling below replaces this with a match against the profile), so `x`, a bare
handle or a bare site name no longer counts. Read on the replica on
2026-11-14, claims processed after they were made in the last 180 days with a link column: 10,334 read, 1,638 with no
filled link field, 8,652 holding a link, 44 with a filled field and no link. The claims behind #60 and #442 (the
two hides merged on 2026-11-13) and the processed claim on 7871c617 each hold a link, so no decision already
acted on changes.

That round could not measure whether the link is to the claimed profile's own page, and said so. The next ruling
closed it (below).

## Ruling 2026-11-14: a link counts only when it matches the profile

Firstmate, 2026-11-14T08:42Z: "a link counts as ownership evidence only when it matches the profile: the same
Spotify/Apple artist id, or a social handle already linked on the Muso profile. Any page-shaped link is not
enough." Aaron's ground: people gaming takedowns.

| what | state on this branch (not deployed) |
|---|---|
| the rule | one place, `sources`: `processed_claims` now carries each processed claim's verification links (`.links`), and `page_facts` matches them against `sources.profile_identity(doc)` — the page's `spotifyId`, a Spotify / Apple artist id in `rawProfiles`, and the handle (`instagram`, `facebook`, `twitter`/`x.com`, `tiktok`, `youtube`) of each social account in the page's `links`. The rule is `updatedat > createdat` at the read AND at least one such match. Ids and handles are compared, never whole URLs |
| what is not a match | a website host, a search-results URL, another artist's Spotify / Apple id, another handle on the same network, a filled field with no link (`x`, `@me`, a bare name), an unreadable profile, a profile that names none of these. Each is the ownership ask, never a pass |
| what it still cannot measure | **who put the links on the profile.** A requester who can edit their page's own links can make the claim match. This is a bar against the instant `created by user` claim, not proof of authorship, and it is recorded as an open risk, not as safety |
| the passthrough | `identity.RULES_V` is 3, so every pass on file is stale and re-decided; `hide-batch` touches no PR while one is stale |
| the access chain | unchanged: it builds a copy from the account's own data and hides nothing |

**Consequence for the two hides merged on 2026-11-13.** #442's claim carries a link matching the page's own Spotify
artist id, so it still passes under the new rule. #60's claim carries only a website link, which is neither a music
artist id nor a social handle: under this rule it no longer passes. #60's page is already hidden, and
`identity.decide_page` answers `ALREADY_HIDDEN` before it reads any claim, so a re-decision neither un-hides it nor
plans it again, and no letter to that requester says their ownership was proven. The rule was not widened to
websites to keep #60 passing.

**The one-message-per-day read was separate from the send claim.** `Store.claim_send_for_person` makes the read
and the claim one write transaction (`BEGIN IMMEDIATE`); `send.deliver` and `Run.access_deliver` claim through it.
Tests: a claim that lands after the early read holds the ladder letter, the identity ask and the Art. 15 answer,
and eight threads on eight requests from one person claim one letter. Five mutations, five caught.

**The day rule could itself delay a statutory answer.** A held Art. 15 answer was only a log line, so the next
day's run found its recorded copy past `access.FRESH_HOURS` and held it for a rebuild nobody performed: the
answer then waited on a person, which the intent forbids ("any wait must be on the requester, never on Muso").
The hold now records the debt on the row (`access_owed_at`), the tick (`access_owed_send`) delivers it on the
next day the person has no message, and it rebuilds the copy through `Run.access_build --record` right before
that send. The answer is offered BEFORE the ladder, so it takes the day and the letter is the one held; a
rebuild that fails or is incomplete is a hold with a reason and the older bytes are never sent. The mark is
written once and cleared once (`Run._access_owed` compares presence, not the clock), so holding the same answer
again on a later tick neither bumps the row's `rev` nor adds an event: `access_owed_at` keeps the day the answer
first became owed. Tests: a day-held answer is rebuilt and delivered by the tick with no operator command and the
stale sha is not the one sent; an incomplete rebuild sends nothing; an answer and a ladder letter due for one
person on one UTC day send the answer and hold the letter, which goes the next day; a second held tick writes
nothing.

**One failing owed row must not stop the tick.** The owed pass runs inside the hourly tick, ahead of
`dsar_ladder`, so an exception escaping one row (an unreadable copy policy, a manifest that will not load, a
ledger write that fails) would skip every other requester's letter and repeat on the next tick. Each row is
contained (`Run.fail` with the register number and the error), the row stays owed and claims nothing, and the
pass goes on to the remaining owed rows and then the ladder. Tests: a raising owed row leaves the tick's ladder
intact and still sends another requester's letter; with two owed rows the first raising does not stop the second.
