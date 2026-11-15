# precedent-untold-tell-r1: tell the precedent_v1 approved-but-untold users

## Result

**41 asked, 0 told, 41 still refused. No customer was sent anything by this task.** Of the 53 on the list, 12 were
dropped as already told and left untouched.

Read back at 2026-11-14T21:55:29Z: 0 of the 41 have a `decision_told` row with `mode='apply'` and `outcome='sent'`,
their newest apply row is from 2026-11-13T20:15:56Z, and no row of any kind was written for the 12
(`evidence/readback41b.out`).

The 41 were asked three times, under three rules. The last one is the current state:

| When | Rule | Outcome |
|---|---|---|
| 20:37Z to 20:49Z | the brief as written (a gate verdict is required) | stopped: this copy has no gate verdict by design (section 3) |
| 21:00Z to 21:09Z | gate condition lifted by firstmate (inbox 001) | 36 `already_told`, 2 `slot_wait`, 3 refused by core (section 7) |
| 21:52Z to 21:55Z | `already_told` keyed on a `sent` row (captain ruling, inbox 003; this branch's code, not deployed) | 38 `slot_wait`, 3 refused by core (section 9) |

Why each of the 41 is still refused, under the ruling:

| Refused by | Users | Reason | Until |
|---|---|---|---|
| The sender's 7-day slot (`decision_told.py`, `slot_wait`; not changed, as ruled) | 38 | each has one live attempt from 2026-11-10 to 11-13 that core did not confirm | 18 open on 2026-11-17, 18 on 2026-11-18, 2 on 2026-11-20 |
| core, in the dry run | 3 | `nothing_owed` (270441, 347304) and `held_messaging_hold` (305363), on every tick, last at 21:38Z | core's answer changes |

The ruling removed the permanent block: before it, the 38 were `already_told` for good. It did not make them
sendable today, because every one of them was attempted inside the last 7 days and the slot was to stay as it is.
The 38 are not one group either. What core answered when each was attempted:

| Group | Users | What the evidence shows | After its slot opens |
|---|---|---|---|
| A. Told by core, hydra never recorded it | 12 (not in the 41) | core stamped `decisionNotice.noticeSentAt` on the attempted requests in the same second as hydra's attempt; hydra lost the answer (6 timeouts, 2 unparseable answers, 4 attempts with no outcome row) | `plan` drops every stamped request, so they are not told twice. 36 unstamped requests of 102783 and 275342 become plannable |
| B. core found no channel | 35 | route answered HTTP 409 `no_channel`: email leg `skipped`, bell `not_visible`, "the user was NOT told" | plannable from an explicit list. firstmate ruled no sends to them (inbox 002): `no-channel-users.txt` |
| C. Notice too large for the mail gateway | 3 | route answered HTTP 503: send-gateway `/v1/send` failed with 413, for notices of 364, 281 and 281 credits | plannable from an explicit list, and would meet the same 413 until the gateway limit moves (section 10) |
| D. core's dry run refuses | 3 | never attempted live; refused on every tick: 2 `nothing_owed`, 1 `held_messaging_hold` | unchanged |

**Nothing re-attempts the 38 by itself.** The 20-minute tick lists nobody who has a live row
(`scripts/credit_review/notify_tick.py:96`, `already_told`, not changed here), so once this is deployed an
unconfirmed attempt is made again only when someone runs `credit-decision-told.py` with an explicit list. That is
what keeps the 35 and the 3 oversize notices from being sent to: no code in this branch names them. Whoever builds
that list has to leave them out. A rule in code (hold a group whose last answer was 413 or `no_channel`) would be a
new sender rule and is not in this branch.

One thing I got wrong on node-8: my own dry run of the list at 21:08Z ran outside the tick's unit environment, so
its three route calls failed with `MUSO_API_URL not set` and never reached core. It wrote three `dry_refused` rows
(ids 4428 to 4430, run `decision-told-dry-62fcd9c893`). **They are not real attempts and they are still there.** I
did not delete them: the table refuses DELETE and UPDATE by trigger (`decision_told_no_delete`,
`decision_told_no_update`), and removing them means dropping a trigger on the production ledger. They change
nothing: `plan`, the slot, the day cap and the ladder read `mode = 'apply'` rows only, the tick reads apply rows
only, and the signed dry run is a file, not these rows. The refusal I report for those three users is the tick's
own, from its dry runs in the right environment.

Per-user rows: `per_user.md`. All 1,949 class requests of the 53 users read `approved` on the replica, so every one
of the 53 does hold an approved precedent_v1 decision.

## 1. The list, recounted (2026-11-14T20:37Z, before any send)

- Source: `/tmp/prec_untold_users.txt` on node-8 (`ovh-node-8`), 343 bytes, mtime 2026-11-14 20:35Z,
  sha256 `4bbf36bbc80604cbd975e6e346da39c07942f7577c89f26a2ae39314bef37239` (unchanged at the read-back).
- **The file holds 53 user ids, all numeric, all distinct.** `wc -l` says 52 because the last line (`368924`) has no
  trailing newline: `wc -l` counts newlines, not lines. So firstmate's 53 is the right count and the 52 is the
  missing final newline, not a missing user.
- Copy of the ids as read: `untold_users.txt`.
- firstmate's totals reproduce on the ledger: 1,202 users with a live attempt plus 3 never attempted is 1,205;
  1,152 of them have a `sent` row; 1,205 minus 1,152 is 53.

## 2. Are the 53 genuinely untold

By the brief's test (an approved precedent_v1 request and no `sent` apply row) all 53 pass. That test reads hydra's
ledger, and for 12 users the ledger is wrong about the customer.

**Group A, 12 users, dropped as already told:** 22104, 29419, 70317, 78042, 84189, 91567, 96558, 100814, 102783,
119162, 212494, 275342.

- Each has a live `attempt` row and no `sent` row: 6 ended in a wrapper timeout (22104, 29419, 70317, 91567, 96558,
  275342), 2 in an answer that did not parse (84189, 119162), and 4 have an attempt row with no outcome row at all
  (78042, 100814, 102783, 212494).
- For each, the requests of the attempted group carry core's own stamp
  `metadata.decisionNotice = {by: agent-uvn-cron@muso.ai, via: agent-status-route, noticeSentAt}`, and
  `noticeSentAt` falls in the same second as hydra's attempt row for all 12 (table in `per_user.md`, groups in
  `evidence/class_groups_53.csv`). 308 requests are stamped this way.
- None of the other 41 users carries any stamp. The 38 whose live call core answered with a refusal (409 or 503)
  each say "nothing was recorded as sent", and none of them is stamped.
- What I did not verify: I did not read core's code for when it writes that stamp. The house wiki note
  `core-trackevent-awaitdelivery-returns-legs` (2026-10-31, confidence medium) records the rule as "a ledger stamp
  must follow a confirmed delivery", and the 38 unstamped refusals are consistent with it. So "told" for these 12
  means core recorded a confirmed notice; I have not seen the email itself.
- These 12 still hold 36 approved class requests with no stamp: 4 in 102783's already-told group, and 32 in a second
  group of 275342. The sender's rule is one notice per group ever, and the tick never lists a user that has any
  live row, so nothing will tell those 36 today.

## 3. The copy gate has no verdict for this copy, and that is not unreviewed copy

The brief said the copy must carry an approved verdict from the gate or the send does not happen. There is none, and
there is nowhere for one to be. firstmate lifted that condition at 2026-11-14T20:53:52Z (inbox message 001) on this
basis: the mail is core's own `credits_accepted` template, and `docs/credit-verification/outbound-copy-gate.md`
lines 141 to 150 list it under "Not behind it", line 149: "Mail that is not ours to word here: core's own status
emails (`credits_accepted`, `credits_rejected`, the claim pair)". Line 160 of the same doc records "core is the
sender of record for an approval; hydra sends no second note". So the missing verdict is not unreviewed customer
copy: it is mail the gate was never meant to hold. What I found:

- The notify path never calls the gate. `copy_gate`, `outbound_copy`, `gate.py` and `sendgate` appear in none of
  `scripts/credit-notify-tick.py`, `scripts/credit-decision-told.py`, `scripts/credit_review/decision_told.py`,
  `notify_chunks.py`, `notify_tick.py` or the host's `/root/mklist2.js` (grep on node-8, `evidence/probe3.out`).
- `gate.py report` on node-8 lists 11 campaigns. None is `decision-approved` or core's `credits_accepted`
  (`evidence/probe3.out`).
- The path has no row in `policies/outbound-copy-senders.json`.
- This is by design, not an omission: `docs/credit-verification/outbound-copy-gate.md` lines 141 to 150 list core's
  own status emails (`credits_accepted`, `credits_rejected`) as not behind the gate, as mail that is not hydra's to
  word. hydra sends no words on this path: the body is `{userId, copyRef, channel, subjectIds, apply}` to
  `POST /admin/notifications/status`, and core renders its own template.

The 1,152 notices already sent on this path went out the same way, with no gate verdict.

## 4. The notify path and an explicit id list

This section describes the sender as deployed, before the ruling in section 9. Its line numbers are those of
`main` at `284745cd6`.

`scripts/credit-decision-told.py` does take an explicit list (`--list F --list-sha S`, lines 51 and 52). It is not
a way to tell these users:

- **50 of 53 have a live attempt row, and the sender never sends twice to an attempted group.** (Section 7 is the
  sender's own answer for the 41: 36 `already_told`, 2 `slot_wait`.)
  `scripts/credit_review/decision_told.py` line 193 drops every group that already has a live row, and lines 202 and
  203 hold the user as `already_told` when no group is left. `run()` writes the attempt row before the call, and an
  attempt that errors stays reserved (line 360). The table is append-only by trigger. Sending to them means changing
  that rule or writing around the ledger, which is the bypass the brief rules out.
- **The other 3 (270441, 305363, 347304) are offered to core on every tick and refused in the dry run.** The 20:36Z
  tick's `last-run.json` gives `route:nothing_owed` for 270441 and 347304 and `route:held_messaging_hold` for 305363
  (`evidence/lastrun.out`). The replica shows 8 and 342 approved unstamped class requests for the first two, so
  `nothing_owed` disagrees with the replica; I did not find the cause.
- The tick is running and not switched off: neither `/etc/hydra/credit-notify-tick.disabled` nor
  `/etc/hydra/credit-decision-told.disabled` exists, and its last status is "sent 0 this run, 3 still untold
  (3 carried, 0 not reached)" with no sender failure (`evidence/lastrun.out`).

Two of the 409 users have a second, never-attempted group (99416: 2 requests; 288257: 1 request). The command-line
sender would plan those from 2026-11-18, when the 7-day slot ends, but the tick will not, because it subtracts any
user with a live row.

## 5. What would actually tell the 41

Written before firstmate's rulings. What was decided since is in sections 8, 9 and 10.

Each is a decision or a change outside this task. I did none of them.

- **B, 35 users, 328 approved credits.** core says there is no channel it can confirm: the email leg was skipped and
  the bell is not visible. The wiki note above gives consent or suppression as what a skipped email leg means; I did
  not check these 35 accounts' mail settings. Telling them needs a different channel, which is a new sender with
  its own copy and its own gate review. Whether a retry today would still answer `no_channel` is not measured: the
  dry run does not test the channel (all 35 had an affirmative dry run between 1 and 25 minutes before the 409).
- **C, 3 users (17097, 50621, 72407), 926 approved credits.** The notice that lists every credit is too large for
  send-gateway (413). core's own message says it may have been delivered and blocks a retry for 7 days. The fix is
  in core or send-gateway (a notice that does not grow with the credit count), then a decision to release the three
  reserved attempts.
- **D, 3 users, 351 approved credits.** 305363 is under a messaging hold in core. 270441 and 347304 need the
  `nothing_owed` answer explained against the replica's unstamped rows.
- **The 12 in group A** need no message. They need the count corrected: "approved minus `sent` rows" overstates the
  untold by 12, and will again for any future timeout. A measure that reads core's stamp would not.

## 6. What was run before the gate condition was lifted

Everything on node-8 up to 20:53Z was a read: the list file, the ledger opened `mode=ro`, the tick's status files,
`gate.py report`, and two replica queries (3 min 14 s and 3 min 57 s, between ticks). No `apply`, no `dry`, no route
call, no file written there. Section 7 lists what was run afterwards.

- `tools/n8.sh`: the hop to node-8 through node-1. `tools/probe1.sh` to `probe5.sh`, `readback.sh` and
  `lastrun.sh`: the reads.
- `evidence/`: their outputs. The per-request replica read (1,949 rows, 395 KB) is not committed;
  `evidence/class_groups_53.csv` is its per-group aggregate and `tools/probe5.sh` reproduces it.
- `evidence/decision_told_host_vs_repo.diff`: node-8's `decision_told.py` still differs from git in 5 hunks (day cap
  from an env var, a query retry and smaller id chunks, the requester email, the answer's `data` wrapper). None is
  in `plan()`. The other four notify files match git at deployed sha `284745cd6`.
- `evidence/host_mklist2.js.txt`: the host's untracked list query.

## 7. The send, pointed at the explicit list of 41 (2026-11-14T21:00Z to 21:09Z)

The 41 are the 53 minus the 12 of group A: `untold_41.txt`.

1. **The list.** Built on node-8 with the tick's own builder (`credit-notify-tick.py` `build_list()`, the host
   query in a core-backend pod), then narrowed to the 41 ids and written in the sender's list format. The class
   read 1,207 users and 10,366 requests at 21:01:36Z; all 41 were in it, with 1,605 requests. List sha
   `9e160845489b`. Scratch files are in `/tmp/precedent-untold-tell-r1/` on node-8 (`tools/send_a_plan.sh`).
2. **`credit-decision-told.py plan --list list41.json --list-sha 9e160845489b --limit 41`** (21:01:36Z to about
   21:04Z, exit 0): `users 41, eligible 3, held {already_told: 36, slot_wait: 2}`. The 3 eligible are 270441,
   305363 and 347304, all under `decision-approved`, 351 requests. A second `plan` on a list of only 99416 and
   288257 answered `held {slot_wait: 2}`, which names the two (`evidence/send_a_plan.json`).
3. **`credit-decision-told.py dry`** on the same list (21:05:16Z to 21:08:02Z, exit 0): the same holds, and the 3
   eligible users came back `dry_refused` with `route call rc=1: ERROR: MUSO_API_URL not set`. That is my run's
   environment, not an answer from core: the tick's unit sets `MUSO_API_URL` and loads the cron account from
   `/etc/openclaw/agents/uvn-cron.env`, and my shell had neither (`evidence/send_b_dry.out`). I did not load that
   account's credentials into an ad hoc shell to repeat it. The tick asks core for exactly these three users every
   20 minutes in the right environment, and its 20:58:07Z dry run answered `nothing_owed`, `held_messaging_hold`,
   `nothing_owed`.
4. **No `apply` was run.** With no affirmed user there is nothing for the ladder to sign
   (`decision_told.py:383-386`), and an `apply` on my dry file would have refused on my environment's zero, not on
   core's.
5. **Read-back** (21:09:32Z, `tools/readback41.sh`, `evidence/readback41.out`): 41 ids; apply rows are 38 `attempt`
   and 38 `error`, 0 `sent`; newest apply row 2026-11-13T20:15:56Z. Rows written for the 41 since 20:50Z: the tick's
   3 dry rows at 20:58Z and my 3 at 21:08Z. Rows written for the 12: none.

The same tick run sent 2 notices to two users who entered the class after the list was made (20016 and 22158).
They are not on this list and not this task's work; fleet-wide `sent` went from 1,152 to 1,154 users.

**Written outside this worktree.** The send was run on node-8, so two things there are mine: the scratch directory
`/tmp/precedent-untold-tell-r1/` (the two lists, the plan and dry outputs, two logs; left in place) and the three
dry rows named under Result. Nothing else on node-8 was changed: no unit, no policy, no kill file, no code.

**What this leaves.** Telling any of the 38 through this path means the sender attempting a group a second time,
which its ledger rule forbids and which I did not change. For the 35 `no_channel` users a second attempt would also
meet core's channel check again. That is a decision about the sender's rule or about another channel, not a list
I can point the path at.

## 8. Follow-up asked by firstmate at 21:00:28Z (inbox message 002)

### The 35 no-channel users

Ids only, one per line: `no-channel-users.txt` (35 lines), also written to
`/home/aaron/fm-creds-1/data/precedent-untold-tell-r1/no-channel-users.txt` as asked. Nothing was sent to them and
no other channel was tried.

They are unreachable by core's own rule, not by hydra's. core counts a user as told only when a leg confirms
delivery: the email was actually sent, or the bell confirmed the user can see it. For these 35 the route reported
email `skipped` and bell `not_visible`, so it answered 409 `no_channel` and recorded nothing as sent
(core-backend `src/services/status-notices/adminStatusNotification.js` lines 585 to 594, read in the local checkout
at `67ea36a310`, which may be behind what is deployed). Until the in-app bell can confirm visibility or these
accounts have an email leg that sends, this path cannot tell them.

Not verified: why each email leg was skipped. core's comment names consent and suppression; a missing address is a
third possibility. I did not read the 35 accounts, so "capture an email" may be the wrong remedy for some of them.

### The 413: located, and not fixable in this repo

The defect is real and is in two other repos. hydra sends no notice body on this path
(`{userId, copyRef, channel, subjectIds, apply}`), so there is no hydra payload to split and no hydra test that
could show a 364-credit notice fits.

- **Where the 413 is raised.** send-gateway reads the body of `POST /v1/send` with a 64 KiB limit:
  `services/send-gateway/src/http.js` `readBody(req, limit = 64 * 1024)` throws `body too large` with status 413,
  and `sendRoute` in `services/send-gateway/src/server.js` (line 621) reads the request through it
  (muso-messaging `origin/main` at `6511d81`, 2026-11-12).
- **Where the body grows.** core builds the notice payload with every credit of the group in it:
  `buildCreditNoticeData({credits, totalTracks: credits.length, ...})` at
  `adminStatusNotification.js` line 578, sent through `sendCreditDecisionNotice`.
- **Where the line falls.** Between 242 and 281 credits: 275342's group of 242 was stamped as sent by core, and
  the three failures are 281, 281 and 364. I did not measure the bytes per credit.

I did not make this change. Both files are outside this worktree and outside this repo, and the choice between the
fixes is not mine:

1. send-gateway: raise the `/v1/send` body limit. One line and a test, no change to what the customer reads.
2. core: cap the credit list in the payload and rely on the count and the existing link. This changes the email a
   customer with a large notice receives, so the template and its copy need review.
3. hydra: send `subjectIds` in pages. This is the only option inside this repo, and I do not recommend it: it turns
   one notice per group into several notices a week apart (core's 7-day slot), each naming a partial count, and it
   changes the sender's one-notice-per-group rule.

Whichever is chosen, the three users (17097, 50621, 72407) stay held afterwards: hydra's ledger has a reserved
attempt for each, which `plan` reads as `already_told`, and core recorded the sends as uncertain. Telling them also
needs a decision to release those three attempts.

## 9. The ruling: a `sent` row closes a group, an attempt holds the slot (inbox 003, 21:15Z)

Ruling (firstmate, 2026-11-14T21:15:01Z): "A message is already told only when there is a decision_told row with
outcome 'sent' for that user+campaign. An attempt without a sent row is re-attemptable." The slot logic was to be
left alone and the 3 core refusals listed, not fought.

What changed in `scripts/credit_review/decision_told.py`:

- `told(db)` is new: the (user, group) pairs with a `sent` apply row. `plan()` takes it as a required keyword and
  holds `already_told` only when every group of the user is in it. Before, any attempt row closed the group.
- The slot is the same line as before (`slot_wait` when any live attempt of the user is under 7 days old).
  `attempts(db)` now returns each group's latest attempt instead of its first. Until today a group had one attempt
  ever, so the two were the same; with re-attempts, the first one would leave the slot open on every later run.
- `run()` re-checks both under the write lock, so a plan made before another run sent or attempted is stopped:
  `already_told` on a `sent` row for the group, `already_attempted` on any attempt of the user inside the slot.
- The file now carries node-8's five hand patches (`evidence/decision_told_host_vs_repo.diff`) and the deploy's
  git-wins marker. Without them a deploy of this change either stops as a conflict or drops the day-cap variable,
  the replica retry, the requester email and the `data` unwrapping the host runs with.

Tests (`scripts/tests/test_credit_decision_told.py`, `DeliveryKeyTest`, 41 in the file): a `sent` row refuses the
group at any age; a user with only dry rows is eligible; a user with only an attempt, or an attempt and an error,
is `slot_wait` inside 7 days and eligible after; a refused attempt is made again after the slot and a confirmed one
then closes the group; the slot counts from the latest attempt; a `sent` user is not sent twice across three runs
and two later slots; a stale plan is stopped under the lock; `plan` without `told` is a TypeError. Each of four
mutations of the rule fails at least one of them.

The re-run (`tools/replan41.sh`, `evidence/replan41.out`, 21:52Z to 21:55Z): this branch's `decision_told.py` and
CLI, placed in a scratch directory on node-8, planned the same list of 41 against a copy of the ledger's
`decision_told` table (4,436 rows). `users 41, eligible 3, held {slot_wait: 38}`. The 3 eligible are the users core
refuses in every dry run. With nothing affirmed there was nothing to sign, so no `apply` was run. The live ledger
was not written, the deployed sender was not replaced, and the ledger copy was removed afterwards.

What I did not do, and why:

- I did not change `notify_tick.already_told`. Keyed on `sent` it would relist all 50 attempted users on every
  tick and, from 2026-11-17, re-attempt the 35 `no_channel` users and the 3 oversize notices every week. Inbox 002
  and 004 rule both out.
- I did not run undeployed code against the live ledger with writes.

## 10. The 413: measured bytes and the proposed gateway limit (inbox 004, 21:19Z)

Ruled (a): raise the gateway limit. **The fix is not in this repository.** It lands in muso-messaging
(`origin/main` at `6511d81`): `services/send-gateway/src/http.js:4`, `readBody(req, limit = 64 * 1024)`, reached
from POST `/v1/send` through `readJson(req)` (`http.js:15`, which passes no limit) in `sendRoute`
(`services/send-gateway/src/server.js:621`). So the change is a limit argument on `readJson` and the bound passed
by `sendRoute`, not a new default for every route. This repository carries the measurement and a test only.

hydra sends no notice body, so what is measured is the list core puts in it: `creditDetails`, one item per Spotify
track, rebuilt from the replica's columns in core's shape (`scripts/credit_review/notice_size.py`, a copy of
core-backend `buildCreditNoticeData`, checkout `67ea36a310`) and serialised as compact UTF-8 JSON. Read on node-8
at 2026-11-14T21:42Z (`tools/notice_bytes.py`, `evidence/notice_bytes.out`; counts and bytes only):

| Credits in the notice | Items after core's dedupe | `creditDetails` bytes | Largest item | What the ledger holds | User |
|---|---|---|---|---|---|
| 119 | 119 | 37,020 | 322 | sent | 334868 |
| 127 | 48 | 16,430 | 408 | sent | 360296 |
| 152 | 89 | 36,315 | 486 | sent | 61448 |
| 195 | 191 | 63,511 | 603 | sent (the largest confirmed notice) | 1333 |
| 242 | 238 | 77,682 | 421 | timeout; core stamped it | 275342 |
| 281 | 281 | 92,556 | 423 | 413 | 72407 |
| 281 | 225 | 127,876 | 806 | 413 | 50621 |
| 364 | 364 | 149,530 | 592 | 413 | 17097 |

Today's limit is 65,536 bytes. The three refused notices are over it by their list alone; the largest confirmed
one is under it by 2,025 bytes.

**Proposed bound: 512 KiB (524,288 bytes) for POST `/v1/send`.** The largest real list is 149,530 bytes, so that is
3.5 times the largest notice measured. A 364-credit notice in which every item is as large as the largest item
measured (806 bytes) is 293,749 bytes, 56% of the bound. It is a bound, not unlimited, and the gateway already reads
another route with `readBody(req, 512 * 1024)` (`server.js:593`).

The test (`scripts/tests/test_credit_notice_size.py`, 17 tests, in PR Validation) builds that synthetic 364-credit
notice, checks its byte count exactly, and asserts it is under the proposed bound and over today's. It also holds
the proposed bound to three times every measured size. The 364 items are synthetic because no customer row is in
the repository; the measured sizes are constants copied from the table above.

What these figures do not establish:

- **They are the list, not the request body.** The body also carries the template key, the address, the profile and
  the person; I did not measure those. The receiving change should verify against its own measurement of a real body.
- **The 242-credit row does not fit the picture and I cannot explain it.** Its list alone is 77,682 bytes, over
  today's limit, yet core stamped its requests as told and hydra saw a timeout, not a 413. Either its email was not
  what confirmed it (core counts a seen bell as told), or the body core sends differs from this rebuild. So 275342
  is the least certain of the 12 "told by core", and "242 passes, 281 fails" is not a boundary this data supports.
- I read the gateway's limit from muso-messaging `origin/main` at `6511d81`, not from the running pod.
- Whether anything after the gateway (the renderer, the mail provider) has its own limit for a 150 KB list.

**The three reserved attempts (17097, 50621, 72407) are not released.** Their slots open on 2026-11-17 and 11-18
under the ruling, but nothing sends to them unless someone lists them, and listing them before the gateway limit
moves sends them into the same 413. 347304 (group D) has a 342-credit group and would meet the same limit if core
stopped refusing it.
