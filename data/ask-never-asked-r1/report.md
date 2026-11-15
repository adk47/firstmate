# ask-never-asked-r1: why the never-asked rows were skipped

Step 1 of three. Scope: pending (`user_verification_needed`) credit requests that no ask names.
The refused group (step 2) and the ladder (step 3) are not touched.

Status of this file: the per-family table was written before any code change. This task ran no
send: the 45 `uvn-reminder-14` reminders reported below were sent by the 21:32Z tick, on signed copy
verdicts. No ask has been delivered to a never-asked request. All reads were read-only (`sqlite3 -readonly`, the core replica through Trino, tick
output files on node-8).

## OURS

| reading | when (UTC) | gauge OURS | corrected OURS | pending | never asked (gauge / corrected) | send refused (gauge / corrected) |
|---|---|---|---|---|---|---|
| before (gauge's own queries, run by hand because the gauge is throttled to one print per 30 min) | 2026-11-14 20:46 | 11,421 | 28,282 | 80,015 | 9,041 / 26,531 | 2,057 / 1,122 |
| re-read by `tools/corrected_ours.py` (nothing sent in between) | 2026-11-14 21:06 | 11,420 | 28,281 | 80,014 | 9,040 / 26,530 | 2,057 / 1,122 |
| after (0 asks sent by this task; the movement is the live queue) | 2026-11-14 21:17 | 11,422 | 28,283 | 80,016 | 9,042 / 26,532 | 2,057 / 1,122 |
| after the 21:32Z tick sent 45 `uvn-reminder-14` reminders (none names a never-asked request) | 2026-11-14 22:09 | 11,425 | 28,304 | 80,037 | 9,045 / 26,553 | 2,057 / 1,122 |

Gauge OURS is `pending - sent` as the gauge computes it. Corrected OURS is pending requests that no
delivered ask names (`pending - (sent ids that are pending)`). The finding survives the re-read:
68,594 request ids have a sent ask, 51,733 of them are pending and 16,861 are not. Re-run with
`python3 data/ask-never-asked-r1/tools/corrected_ours.py` (two reads, core replica and node-8
ledger, joined by request id; they are two stores, so it cannot be one query).

## The gauge counts 16,861 delivered asks on requests that are no longer pending

`verif-lane.check.sh` computes `ours = pending - sent`, where `sent` is every request id in
`verify_requests` whose message row is `sent`. That count is not restricted to requests that are
still pending. Joined by request id (80,015 pending ids from the replica against 70,974 distinct
ledger ids, both read 2026-11-14 20:48Z):

| | requests | users |
|---|---|---|
| pending | 80,015 | 7,259 |
| pending, named by a sent message | 51,733 | 4,755 |
| pending, named only by a refused or rejected message | 1,122 | 92 |
| pending, named only by a skipped / attempted row | 629 | 66 |
| pending, no `verify_requests` row at all | 26,531 | 2,863 |
| sent request ids that are not pending any more | 16,861 | |

So the pending requests with no delivered ask are 28,282, not 11,421, and the never-asked rows are
26,531, not 9,041. The gauge script is firstmate's and outside this worktree; it is not changed here.
The rest of this report attributes the 26,531.

Check on the join: only 5 of the 26,531 are named in the `request_ids_json` of a sent message
without a `verify_requests` row (all `first-ask-1`), so `verify_requests` is a complete record.

## Per family: the 26,531 never-asked rows

Source for the split: the builder's own list of the 20:31Z tick (`owing.json`, rebuilt 20:43:22Z on
deployed head `284745cd6`), which classes every owed row.

| family that covers the rows | requests | users | cause | kind of cause |
|---|---|---|---|---|
| `uvn-status` (class `uvn`, user never told) | 10,888 | 737 | held per user, see next table | hold markers |
| `uvn-new-rows` (class `uvn_new_rows`, user told before, these rows are newer) | 7,817 | 874 | no tick family runs the campaign, and the gate send-locks it (`UVN_NEW_ROWS_COPY_APPROVED=0`) | copy lock |
| none: core asked these itself (`metadata.proofRequest` with `noticeSentAt`), request has a user | 7,408 | 1,958 | not owed an ask; the builder skips them as already told (`owing_proof.py:270`), the gauge reads the verify ledger only | not a skip |
| none: request has no `userid` (3 of them also carry core's marker, counted here only) | 413 | - | nobody to write to | no channel |
| none: not on any list | 5 | 2 | not determined (users 119185, 100311) | unknown |

Each request is in one row: 10,888 + 7,817 + 7,408 + 413 + 5 = 26,531.

`uvn-new-rows` split: paid 3,085 requests / 381 users, free 4,732 / 493. It has 0 sent rows ever.
`scripts/credit-verify-outbound.sh` has no reference to the campaign; the gate refuses a live post
with "send-locked until p1 + r5 sign its first dry run on the deployed head"
(`scripts/intercom-verify-request.sh:1959`). Its copy (`fable-copy-1101-r5/n1`) exists.

Core-asked rows (all 7,411 that carry the marker, the 3 with no user id included): 7,410 carry reason `validator_band_hint`; `noticeSentAt` is 2026-10 on 2,591 and
2026-11 on 4,800 (20 could not be parsed from the 300-character extract). Whether core's notice
reached the customer is not measured here: the marker is the only evidence.

Causes ruled out for every family, with the evidence:

- **Page cut**: not a cause. The uvn-status cursor walks the whole list every two ticks (paid
  0-643 then 643-914; free 0-1193, 1193-2220, 2220-2229 on 2026-11-14).
- **Per-run cap**: not a cause. The paid check of 20:31Z accepted 0 of 916 against a cap of 50; of the
  16 uvn-status checks since 12:00Z the accepted counts were 0, 0, 0, 0, 0, 2, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0.
- **Status filter**: not a cause for the listed rows; the builder lists `user_verification_needed`
  positively (`OPEN_STATUSES`).
- **Age window**: not a cause. Never-asked rows span 2024-08 to 2026-11 (17,075 of them created in
  2026-10 and 2026-11).
- **90-day ask lock**: 4 paid users and 12 free users per walk on the whole list.

## `uvn-status`: cause per user for its 10,888 never-asked rows

Per-user gate outcomes come from the `uvn-status-{paid,free}-check.json` files of the ticks since
2026-11-14 12:00Z (newest outcome per user). The runner counts its own list holds but does not
record them per user, so a user with no gate outcome is placed by the proof-on-file export
(`/var/lib/credit-trust/proof-on-file.json`, generated 19:58Z).

| segment | users | requests | cause | owner |
|---|---|---|---|---|
| free | 311 | 7,203 | user has a document on file, no gate call made | stage 2 verdict (`stage2_verdicts`) |
| paid | 218 | 1,341 | same | same |
| free | 90 | 801 | runner hold not recorded per user (already handled, approval path, fraud lens, blank fields) | not attributable from the logs |
| paid | 5 | 54 | same | same |
| free | 21 | 273 | gate refused: account email matches more than one Intercom user | `intercom-reconcile` |
| free | 1 | 267 | emailed support@ in the last 90 days | `SUPPORT_CONTACTED_HOLD` lane |
| free | 15 | 201 | `HELD comm_state` (replied, account hold, already acknowledged) | comm_state |
| paid | 5 | 156 | same | same |
| free | 12 | 146 | `messaged_7d` | clears with time |
| paid | 5 | 45 | same | same |
| free | 1 | 121 | gate call timed out (unmeasured) | retried next walk |
| free | 9 | 81 | gate refused `G5` (a field carries a link, address or markup) | request data |
| paid | 1 | 1 | same | same |
| free | 13 | 63 | `core_notice_within_7d` | clears with time |
| paid | 1 | 1 | same | same |
| free | 14 | 38 | `c2_signed_only` (class C corrected ask is signed-only on the timer) | arming row `uvn-status:c2` |
| paid | 9 | 34 | same | same |
| free | 3 | 34 | gate refused: Intercom user has no external id / belongs to another account / two this account | `intercom-reconcile` |
| free | 1 | 14 | `inapp_not_armed` (email unreachable, in-app route not armed) | arming |
| free | 1 | 13 | gate refused: the note contains a word the outbound sanitiser bars | request data |
| free | 1 | 1 | `HELD no_channel` (Intercom `action_forbidden`) | no channel |

The document-on-file rows are an upper bound: 529 users are in the export and reached no gate call,
but the runner applies its other holds to some of them first. The runner's own count of
"documents on file (not asked)" for the whole list was 454 of 916 paid (393 + 61 over the two pages)
and 922 of 2,235 free (572 + 350), against 651 paid and 1,128 free placed here by the export.

## What this means for delivery

- **`uvn-status`**: no cap, page or copy lock is in the way, so there is nothing to unlock in the
  sender. Where the cause is recorded it is a marker that has an owner, or a wait that clears with
  time: at most 8,544 of the 10,888 rows wait on a stage 2 verdict for a document the customer
  already sent (an upper bound, placed from the export), which is a decision, not an ask.
  **Not known: 95 users / 855 requests** were held by the runner with no reason recorded per user.
  Nothing here shows what holds them.
- **`uvn-new-rows`**: 7,817 rows would be asked and are stopped by the copy lock. This family stops
  for a verdict. Nothing is sent for it and no verdict is minted here.
- **Core-asked rows**: 7,408 rows (7,411 carry the marker; the 3 with no user id are counted under no channel) are not owed an ask by the ledger's sender.

Asks delivered to never-asked requests: 0. Stopped: `uvn-new-rows`, by the sender's copy lock (see
"The two copies at the gate").

## The never-asked rows, one cell each (inbox 004)

Every never-asked pending request is in exactly one row below: family, segment, the exact stop, and
the request's age (from `createdat`). Produced by `python3 data/ask-never-asked-r1/tools/map_never_asked.py`
over the snapshot of 2026-11-14 20:48Z.

**The rows sum to 26,531, not 26,545.** 26,531 is the never-asked count of the snapshot the map is
built from; 26,545 is a later reading of the same live count (80,029 pending). The 14 requests that
arrived in between are not mapped.

| family | segment | stop | kind | 0-7 d | 8-30 d | 31-90 d | 91-180 d | over 180 d | requests |
|---|---|---|---|---|---|---|---|---|---|
| `uvn-new-rows` | free | copy lock `UVN_NEW_ROWS_COPY_APPROVED=0`; no tick family runs it | copy lock | 609 | 2,666 | 314 | 338 | 774 | 4,701 |
| `uvn-new-rows` | paid | copy lock `UVN_NEW_ROWS_COPY_APPROVED=0`; no tick family runs it | copy lock | 682 | 872 | 419 | 883 | 260 | 3,116 |
| `uvn-status` | free | document on file, no stage 2 verdict (`stage2_verdicts`) | hold marker | 227 | 1,602 | 492 | 2,204 | 2,678 | 7,203 |
| `uvn-status` | free | runner hold, not recorded per user | not determined | 92 | 382 | 145 | 66 | 116 | 801 |
| `uvn-status` | free | Intercom identity refusal (`intercom-reconcile`) | hold marker | 1 | 89 | 19 | 127 | 71 | 307 |
| `uvn-status` | free | `SUPPORT_CONTACTED_HOLD` (emailed support@ in 90 d) | hold marker |  | 267 |  |  |  | 267 |
| `uvn-status` | free | `HELD comm_state` | hold marker | 2 | 157 | 18 |  | 24 | 201 |
| `uvn-status` | free | `messaged_7d` | 7-day wait | 5 | 31 |  | 50 | 60 | 146 |
| `uvn-status` | free | gate call timed out | unmeasured |  |  | 9 | 112 |  | 121 |
| `uvn-status` | free | gate refusal `G5` (field carries a link or markup) | hold marker |  | 44 | 17 | 10 | 10 | 81 |
| `uvn-status` | free | `core_notice_within_7d` | 7-day wait | 59 | 2 |  | 2 |  | 63 |
| `uvn-status` | free | `c2_signed_only` (arming row `uvn-status:c2`) | hold marker | 26 | 12 |  |  |  | 38 |
| `uvn-status` | free | `inapp_not_armed` | no channel |  | 14 |  |  |  | 14 |
| `uvn-status` | free | other gate refusal: gate refused: the rendered note contains | hold marker |  |  |  |  | 13 | 13 |
| `uvn-status` | free | `HELD no_channel` | no channel |  |  |  | 1 |  | 1 |
| `uvn-status` | paid | document on file, no stage 2 verdict (`stage2_verdicts`) | hold marker | 142 | 1,048 | 32 | 99 | 20 | 1,341 |
| `uvn-status` | paid | `HELD comm_state` | hold marker |  | 14 | 133 | 1 | 8 | 156 |
| `uvn-status` | paid | runner hold, not recorded per user | not determined | 16 | 38 |  |  |  | 54 |
| `uvn-status` | paid | `messaged_7d` | 7-day wait | 28 | 14 |  | 1 | 2 | 45 |
| `uvn-status` | paid | `c2_signed_only` (arming row `uvn-status:c2`) | hold marker | 11 | 23 |  |  |  | 34 |
| `uvn-status` | paid | `core_notice_within_7d` | 7-day wait |  | 1 |  |  |  | 1 |
| `uvn-status` | paid | gate refusal `G5` (field carries a link or markup) | hold marker |  | 1 |  |  |  | 1 |
| none | free | request has no `userid` | no channel | 2 | 90 | 38 | 16 | 267 | 413 |
| none | free | on no list | not determined | 5 |  |  |  |  | 5 |
| none (core asked) | free | core `proofRequest` notice already sent; not owed a ledger ask | not a stop | 1,423 | 2,226 | 9 | 60 | 307 | 4,025 |
| none (core asked) | paid | core `proofRequest` notice already sent; not owed a ledger ask | not a stop | 1,503 | 1,774 | 3 | 70 | 33 | 3,383 |
| **total** | | | | 4,833 | 11,367 | 1,648 | 4,040 | 4,643 | **26,531** |

By kind of stop: hold marker 9,642; copy lock 7,817; not a stop 7,408; not determined 860; no channel 428; 7-day wait 255; unmeasured 121.

Reading the table:

- **Copy lock: 7,817.** All of `uvn-new-rows`. One stop, one owner: the gate constant
  `UVN_NEW_ROWS_COPY_APPROVED=0` (`scripts/intercom-verify-request.sh:511`), which opens on a signed
  first dry run on the deployed head (p1 + r5), and no tick family runs the campaign.
- **Owned hold markers: 9,642.** 8,544 of them are one marker: a document on file with no stage 2
  verdict (owner `stage2_verdicts`; the count is an upper bound, see "Not verified"). The others:
  `HELD comm_state` 357, Intercom identity refusals 307 (`intercom-reconcile`), `SUPPORT_CONTACTED_HOLD`
  267, gate refusal `G5` 82, `c2_signed_only` 72 (arming row `uvn-status:c2`), outbound sanitiser 13.
- **Cap: 0 in this table.** A request is placed by its builder class, and neither `uvn-status` nor
  `uvn-new-rows` is stopped by a cap. The `proof-need-ask` free page cut (cap 5, the change in this PR)
  holds 3,677 never-asked requests that are also on that family's list; those same requests appear
  above under their builder class.
- **No channel: 428.** 413 requests with no `userid`, 14 `inapp_not_armed`, 1 `HELD no_channel`.
- **Stale verdict: 0 found.** No never-asked row is held on a verdict that went stale; the one stale
  marker seen on these lists (`wait:stale_filing`, `proof-need-ask`) is on rows counted above by class.
- **`uvn-reminder-14`: 0 never-asked rows.** A reminder names only rows a sent ask already named, so
  it can deliver nothing to this population. Its own stop is `copy_review_pending` on every body.
- **Not a stop: 7,408.** Core sent its own `proofRequest` notice for these; the builder treats the
  user as told and the verify ledger has no row for them. (7,411 carry the marker; 3 of those have no
  `userid` and are counted under no channel.)
- **Not determined: 860.** 855 requests of 95 `uvn-status` users the runner held without recording
  why, and 5 requests on no list.

## The two copies at the gate (inbox 004, read 2026-11-14 21:46-21:48Z)

### `uvn-reminder-14`: the gate is now answering, and the tick is the sender

- From 18:55Z to 21:26Z every reviewer round on ak47 answered `"skipped_bad_request": 100` for the
  held reminder bodies and reviewed none of them (`journalctl --user -u outbound-copy-review.service`).
  That is the documented failure of a reviewer host whose installed `gate.py` is older than node-8's.
- The reviewer host was re-installed at 21:37:46Z (backup `outbound-copy-review.bak-20261114T213746Z`).
  This task did not do that. The next round (21:40Z) answered
  `"review": {"approve": 60, "refuse": 0, "rewrite": 0, ...}, "waiting": 160` and stored 60 signed verdicts.
- node-8, `gate.py report` at 21:47Z: `uvn-reminder-14` approve 39, pending 61, refuse 0, rewrite 0.
  `gate.py pending-age`: 100 held, oldest 10,392 s. The round reviews 60 bodies every 15 minutes.
- The ledger still holds 100 reminder rows `deferred` (`copy_review_hold: copy_review_pending`), 0 sent.
  A hold gives the claim back, so the tick offers the same users again; the reminder family of the
  21:32Z tick had not run yet at 21:48Z.
- Nothing was run by hand for this copy: the round and the tick are the existing path. An apply takes
  its campaign's run lock (`uvn_status.py:1640`), so a hand-run apply beside the tick would make the
  tick's own reminder apply halt with "another uvn-reminder-14 apply run is in progress".
- **Sent: 45 reminders, each on a signed verdict.** The reminder family of the 21:32Z tick ran at
  21:56-22:07Z: paid 21 sent and 29 held `copy_review_pending`; free 24 sent and 5 held. The ledger at
  22:09Z: 45 `sent` rows, 45 users, 256 credits named, a `copy_verdict_id` on all 45; 100 rows `deferred`
  on `copy_review_pending`. `gate.py report` at 22:09Z: approve 75, pending 25, refuse 0, rewrite 0.
  The held bodies are offered again by the next tick, 50 a tick across both segments.
- **OURS did not go down.** Corrected OURS was 28,283 at 21:17Z and 28,304 at 22:09Z; the never-asked
  count went from 26,532 to 26,553. Pending rose by 21 in the same 52 minutes (80,016 to 80,037) and
  the reminders name no never-asked request, so the whole movement is new pending requests.
- **This copy cannot lower the never-asked count.** A reminder names only rows a sent ask already
  named, so every request it reaches already has a delivered ask. Its sends are reported, but neither
  gauge OURS nor corrected OURS moves on them.

### `uvn-new-rows`: stopped before the copy gate, by the sender's own lock

The copy gate was not asked about this copy and cannot be asked through the send path: the sender
refuses a live post first, and it calls the copy gate only on a live post, after that refusal
(`scripts/intercom-verify-request.sh:1959`, gate call at `:4093`). The refusal, verbatim:

> uvn-new-rows is a NEW class, send-locked (UVN_NEW_ROWS_COPY_APPROVED=0) until p1 + r5 sign its first dry run on the deployed head; --dry-run / --check-recipient only. Nothing was sent or claimed.

`gate.py report` on node-8 has no `uvn-new-rows` row: no body of this campaign has ever reached the gate.

What a send of this copy needs, none of which this task may do:

1. `UVN_NEW_ROWS_COPY_APPROVED=1` in the sender (a constant; inbox 003: do not touch the copy lock).
2. A tick family that runs the campaign, and its arming row in `policies/credit-verify-outbound.json`
   (inbox 004: do not touch the policy file).
3. A merge and a deploy.

One more fact for whoever opens the lock: `uvn-new-rows` is not in the `enforce` list of
`policies/outbound-copy-enforce.json`, so it takes the default, `observe`. With the lock open and
nothing else changed, the gate would answer `observed` and the note would go out without a signed
approve. `uvn-reminder-14` was put in `enforce` from its first body for that reason.

The gate's reading of this copy is therefore not known. Getting it would mean a hand-run dry run of
the campaign on node-8 and a hand-written `gate.py check` into node-8's copy store, with the body,
`--copy`, `--kind` and `--message-type` reproduced outside the sender. That was not done: a verdict on
bytes the sender did not produce is not a verdict on what it would send, and no verdict can lead to a
send here while the three items above stand.

## Not verified

- The per-user document-on-file placement is from the export, not from the runner (see above).
- The 95 users under "runner hold not recorded per user" have no cause named.
- Whether core's proof notice was delivered for the 7,411 marker rows.
- The two free uvn-status accepts (15:00Z, 16:00Z, 19:32Z checks accepted 2, 1, 1) were not traced to
  a sent row.

## Delivery half: every family whose list names a never-asked row (measured 2026-11-14 21:10-21:16Z)

Added after the table above. The first table places each row in one builder class. The lists of two
more families name some of the same rows, so the counts below overlap and do not sum to 26,531.
Nothing was sent by this task up to this section.

| family | copy lock in the gate | armed on the tick | never-asked requests its list names | users | sent 13-14 Nov | cause it did not ask them |
|---|---|---|---|---|---|---|
| `uvn-status` | open (`UVN_STATUS_COPY_APPROVED=1`) | yes | 10,888 | 737 | 190 | hold markers per user (table above); no cap, page or lock |
| `uvn-new-rows` | **locked** (`UVN_NEW_ROWS_COPY_APPROVED=0`) | no family runs it | 7,817 | 874 | 0, ever | copy lock: stops for a verdict |
| `proof-need-ask` paid | open (`PROOF_NEED_ASK_COPY_APPROVED=1`) | yes | 2,925 | 490 | 15 (both segments) | gate holds, and the per-tick cap of 50 (table below) |
| `proof-need-ask` free | open | yes | 4,785 | 526 | 0 accepted in 26 ticks | **page cut by the per-tick cap of 5** (below) |
| `r1` receipt (`status-doc-received`) | open (`STATUS_RECEIVED_COPY_APPROVED=1`) | yes | 8,763 | 1,047 | 0 | gate holds and unreadable filings (table below); a receipt asks for nothing |
| `uvn-reminder-14` | open, but every body needs a signed verdict | yes | 0 | 0 | 0 (100 deferred `copy_review_pending`) | follows a sent ask, so it names no never-asked row; stops for a verdict |
| `gap-ask` | **locked** (`GAP_ASK_COPY_APPROVED=0`) | no | not measured | | 0 | copy lock |
| `score_approve`, `claim-proof-ask`, `claim-status` | | | 0 | | | not ask families for a credit request: one approves, two write about claims |

### `proof-need-ask` free: the cap of 5 is a page cut

`policies/credit-verify-outbound.json` `tick_cap["proof-need-ask"] = {"free": 5, "paid": 50}` (the
live node-8 file reads the same, 21:14Z). The cap bounds the users handed to the gate, accepted or
not, and the cursor stops at the first user not examined (`need_asks.py` `_send`, `page.end`). Over
the 26 free ticks from 2026-11-13 00:00Z to 2026-11-14 17:36Z:

- the cursor moved from entry 672 to entry 823, 151 entries, about 6 a tick;
- the list grew from 745 to 885 entries in the same time, 140 entries;
- 130 users reached the gate and 0 were accepted (59 refused `G2`, the filing conversation was
  opened by us; 26 `HELD comm_state`; 25 `messaged_7d`; 13 `core_notice_within_7d`; 7 other);
- 840 list entries were set aside as `over --max-users 5 (a later batch)`.

At that rate one pass over the free list takes about 150 ticks. In the paid segment, at 50, the
check accepted 18 of the 1,258 users the gate saw in the same 26 ticks (1.4%).

Newest outcome per user for the never-asked rows the list names (ticks since 2026-11-13 00:00Z):

| segment | users | requests | newest outcome | kind |
|---|---|---|---|---|
| free | 385 | 3,565 | no outcome in any page | page cut (cap 5) |
| free | 36 | 112 | over `--max-users` | cap |
| free | 17 | 541 | filtered: a filing newer than the document (`distributor_dashboard_with_code`) | hold |
| free | 38 | 353 | refused `G2`: filing conversation opened by us | hold |
| free | 39 | 170 | `HELD comm_state` / `messaged_7d` | hold or wait |
| free | 10 | 32 | `core_notice_within_7d` | wait |
| free | 1 | 5 | refused: conversation has several contacts | hold |
| paid | 232 | 980 | over `--max-users` | cap |
| paid | 124 | 933 | `HELD comm_state` (account hold 9 / 422, replied 53 / 299, wrote after the document 53 / 175, stale thread 8 / 36, watchlist 1 / 1) | hold |
| paid | 54 | 383 | `core_notice_within_7d` | wait |
| paid | 45 | 377 | filtered: a filing newer than the document | hold |
| paid | 1 | 133 | gate call timed out | unmeasured |
| paid | 23 | 85 | `messaged_7d` | wait |
| paid | 8 | 30 | refused `G2` / several contacts | hold |
| paid | 3 | 4 | no outcome in any page | not determined |

The 232 paid users whose newest outcome is the cap were not followed further. The paid cursor went
from entry 444 to 591 at 11:00Z and from 648 back to 0 at 12:00Z on 2026-11-14, and why those two
stretches were passed over was not found.

What a higher free cap would deliver is not measured. On the paid rate of 1.4% the 421 free users
the cap keeps from the gate would yield about 6 asks; the free gate rate measured so far is 0 of 130.

### `r1` receipt: cause per user for the 8,763 never-asked requests on its received list

By builder class those requests are 3,243 core-asked, 2,976 `uvn_new_rows` and 2,544 `uvn`. `r1`
accepted 0 users in every tick of 2026-11-14. Newest gate outcome per user:

| users | requests | cause |
|---|---|---|
| 226 | 3,389 | no gate outcome recorded for the user |
| 467 | 2,522 | `HELD r1_receipted_in_thread`: an admin already acknowledged the document in the thread |
| 64 | 927 | refused `r1_unreadable_filing`: the doc reader found no text |
| 149 | 809 | `core_notice_within_7d` |
| 98 | 549 | refused `r1_filing_class_unknown` |
| 24 | 483 | refused: the filing is a screenshot of Muso |
| 4 | 30 | `HELD comm_state` |
| 7 | 23 | refused on the filing conversation (contacts, opened by us, no conversation named) |
| 3 | 18 | refused on Intercom identity |
| 2 | 8 | gate call timed out |
| 3 | 5 | refused, other |

### What was sent, and what stopped

Asks sent by this task: 0.

- Stopped for a gate verdict, 2 families: `uvn-new-rows` (copy lock, 7,817 never-asked requests) and
  `uvn-reminder-14` (no signed verdict on its bodies; it names no never-asked row).
- `uvn-status` and `r1` already run every tick with open copy and no cap or page in the way, so a
  manual run would meet the same gates. Where a gate outcome or a recorded hold names the cause, it is a marker with its own owner or a 7-day wait 
  Not every row has one, and those rows are not shown to be held by anything: on `uvn-status`, 95 users / 855 requests were held by the runner with no reason recorded per user;
  on `r1`, 226 users / 3,389 requests have no gate outcome. Their cause is not known.
- `proof-need-ask` free is the one family where the cause is a setting of the sender: the per-tick cap
  of 5. It is a live policy value, and raising it needs a merged policy change and a deploy, neither of
  which this task does.
  The value was set on node-8 by hand and carried into the repo on 2026-11-13 as "the values node-8
  already runs"; no reason for 5 is recorded in the repo or the house wiki.

OURS did not move because of this task: corrected OURS was 28,281 at 21:06Z and 28,283 at 21:17Z.

## The cap change (firstmate decision 2026-11-14 21:19Z, inbox 003)

`policies/credit-verify-outbound.json` `tick_cap["proof-need-ask"]["free"]`: 5 to 50, the value the
paid segment already runs at. The live node-8 file was byte-identical to the repo copy before the
change (sha256 `0a48dba7...9454`, read 21:21Z), so a deploy changes this one value and no other.

| | before | after |
|---|---|---|
| free users handed to the gate per tick | 5 | 50 |
| per hour at the measured cadence (26 free ticks in 41.6 h, one per 1.6 h) | about 3 | about 31 |
| per hour if every hourly tick ran | 5 | 50 |
| ticks for one pass over the free list (885 entries) | about 150 (about 10 days) | about 15 (about 1 day), on the paid segment's 62 entries a tick |

- Replay on production data, read-only, no gate call: applying the runner's own selection at 50 to
  the 26 free ticks' check files gives 939 users handed to the gate against the 130 that were, 36 a
  tick (14 to 50, median 37), about 23 an hour at the measured cadence. It is a lower bound if the
  tick sizes the free page by the cap; that was not checked.
- The cap bounds users handed to the gate, not asks delivered. Asks per tick are not known for free:
  the free gate accepted 0 of 130 on 13-14 Nov, the paid gate 18 of 1,258 (1.4%). At the paid rate
  that is under 1 ask a tick and about 6 from the 421 users the cap kept back.
- Unchanged: one note per account per UTC day, the copy lock and the copy gate, every hold marker,
  `daily_cap["proof-need-ask"]` 400 per segment, the shared credit ceiling of 2,500 a day and the
  90-day ask lock.
- Order inside the tick is unchanged: the need group runs last, free before paid. The extra free
  checks are therefore spent before the paid `proof-need-ask` segment starts.
- 50 is enough to walk the backlog: all 421 held-back users reach the gate inside one pass, about a
  day. What limits delivery after that is the gate's accept rate, not the cap, so no larger number is
  proposed.
- Cost: 45 more gate checks per tick, about 3 minutes at the tick's own 4 s per user.
- Revert: `git revert` of the one commit. It is one policy line (50 back to 5) and the one test line
  that pins it (`scripts/tests/credit-verify-outbound.bats`), then a deploy.
- The policy's `_doc` still describes the 2026-11-13 reconciliation ("free: 5", "nothing is raised");
  it is left as the dated record it is.
- Nothing takes effect until a merge and a deploy. Compare the live file with the repo again before
  deploying: the node-8 watchdog and operators edit it in place.

## `uvn-new-rows` on the deployed head: who the sender itself would ask (inbox 005, 2026-11-14 22:19-22:22Z)

Read-only. The builder was run on node-8 on deployed head `96c5a2fb8` with `--class-out uvn_new_rows=`
(13 s), and the sender's own dry run (`credit-review.py uvn-status --campaign uvn-new-rows --mode dry-run
--check-recipients`, the mode the lock allows) was run on the first 60 list entries of each segment.

The class list: 1,404 users (656 paid, 748 free), 22,681 requests, of which 7,820 are never-asked.

The dry run accepted 1 of the first 60 paid entries and 0 of the first 60 free entries, with no gate
outcome recorded: the runner held the others itself. Its per-user reason, read from the ledger with the
deployed `verify_ledger.new_rows_user_done` for every user on the list (by user id only, so a ledger row
keyed by an old email alone is not seen):

| segment | runner's answer | users | listed requests | never-asked requests |
|---|---|---|---|---|
| paid | `no_prior_ask`: no SENT `uvn-status` ask, so the opener "Since we last wrote" would be false | 506 | 9,563 | 2,770 |
| free | same | 566 | 11,246 | 4,240 |
| paid | `proof_received` (closed) | 37 | 165 | 92 |
| free | same | 33 | 262 | 95 |
| paid | `messaged_7d` (clears with time) | 21 | 179 | 48 |
| free | same | 39 | 460 | 118 |
| paid | may be asked, before the document hold and the gate | 92 | 406 | 206 |
| free | same | 110 | 400 | 251 |

So opening the copy lock reached at most 202 users and 457 never-asked requests at that reading, not 7,817: 7,010 of
the 7,820 never-asked requests on this list belong to users the family defers as `no_prior_ask`. The
builder puts a user in this class when a sent ask OR core's own proof notice told them; the sender
requires a sent `uvn-status` ask. A user core told and we never asked is in neither family's reach:
`uvn-status` skips them as already told, `uvn-new-rows` defers them for having no prior ask.

Read again at 22:45Z with the account email as well as the user id (the two arguments the runner passes):
`no_prior_ask` is unchanged at 1,072 users / 7,010 never-asked requests, so the by-user-id read missed no prior
ask. `proof_received` 70 / 187, `messaged_7d` 107 / 235 (up, because the 21:32Z tick's reminders went to some of
these users), may be asked 155 / 388. The most the family can reach, once the 7-day waits clear, is 262 users
and 623 never-asked requests.

The sender's dry run of 22:31-22:42Z (first 320 candidates per segment, `--max-users 6`) accepted 6 paid and 6
free users; its "159 left for the next run" (paid) and "118" (free) are candidates the walk stopped before, not
users it accepted. The six paid bodies, the copy gate's answers and the six signed verdict ids are in
`uvn-new-rows-bodies.md`.

## `uvn-new-rows`: the lock, the family and the cap (inbox 007, 2026-11-14 22:48-23:20Z)

Three commits on this branch. Nothing is deployed, so nothing was sent by them.

| commit | what |
|---|---|
| `487d8d0ad` | `UVN_NEW_ROWS_COPY_APPROVED` 0 -> 1; `uvn-new-rows` added to `enforce` in `policies/outbound-copy-enforce.json`; the sender holds any answer but a signed `approved` for this campaign, as it does for the reminder |
| `6fb778cc0` | the tick family `new_rows_family`, its `armed_families` row, `daily_cap` 120/120, `tick_cap` 5/5, the campaign in the credit group |

The human sign-off the lock named ("until p1 + r5 sign its first dry run on the deployed head") is replaced by the
copy gate's signed verdict on the six bodies of that dry run (verdict ids in `uvn-new-rows-bodies.md`).

### What 5 per tick reaches against 7,817

The cap is `NR_CAP` = 5 users per tick, paid and free together, paid first.

| | users | never-asked requests | share of 7,817 |
|---|---|---|---|
| one tick, at most | 5 | about 13 (2.5 a user: 388 / 155) | 0.16% |
| one day, at most (24 hourly ticks; `daily_cap` 120 a segment) | 120 | about 300 | 3.8% |
| one day at the measured cadence (one tick per 1.6 h, 15 ticks) | 75 | about 190 | 2.4% |
| everything the family can reach at any cap (22:45Z) | 262 | 623 | 8.0% |
| out of the family's reach at any cap (`no_prior_ask`) | 1,072 | 7,010 | 89.7% |

- The cap is 1.9% of the reachable 262 users, so no run clears the backlog: at 5 a tick the reachable users take
  53 ticks or more.
- These are upper bounds. The document-on-file hold, the fraud lens, the 7-day waits and the gate still apply to
  each of the 5, and the accept rate under the cap is not measured: the dry run of 22:31-22:42Z stopped at its own
  `--max-users 6` in each segment.
- The first tick after a deploy is expected to send 0: each body is new, so it is held as `copy_review_pending`
  until the reviewer round signs it, and it goes on a later tick. That is what the reminder did (100 held, then 45
  sent one tick after the round).
- 7,010 of the 7,817 are not moved by this family at any cap. They belong to users core's notice told and we never
  sent a `uvn-status` ask; no family asks them. That is a finding, not something this change fixes.

The live policy file on node-8 (deployed head `c1fbf5a22`, read 23:17Z) differs from this branch's copy only by this
branch's own changes: the `uvn-new-rows` rows and `tick_cap["proof-need-ask"]["free"]` 5 -> 50.
