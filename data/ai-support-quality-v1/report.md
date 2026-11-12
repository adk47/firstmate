# AI support quality v1: why Caroline's threads do not close

Read 2026-11-12 02:15Z from the live Intercom inbox (read-only: `POST /conversations/search`,
`GET /conversations/{id}`) and from the output-guard ledger on node-8
(`/var/lib/hydra/injection-watch/ledger.jsonl` plus its sealed daily files).

Window: the 24 hours ending 2026-11-12T00:45:00Z (the instant the captain's numbers were read).

## What was read

| | |
|---|---|
| Conversations touched in the window (`updated_at` inside it) | 2,247 listed, Intercom says 2,247, 2,247 read, 0 errors, 0 gone |
| Of those, the customer wrote in the window | **417** |
| Output-guard blocks in the window (ledger rows, `kind: output_guard`) | 63 rows on 60 conversations, all 60 inside the 417 |

The 417 and the outcome counts below reproduce the captain's read exactly (58 resolved, 63
handed to a person, 205 told a person is coming with nobody assigned), so the cause histogram
is counted on the same measurement.

## Status of this classification

**Rule-read, partly hand-checked.** Every thread is placed by code: what the customer asked
(`shape`, the caroline-intent-mining-m1 taxonomy), what happened after their first message in
the window (`outcome`), and whether the guard ledger has a block row for it. The guard class is
exact (it is a ledger join, not a text match). The other classes are regexes over text; seven
`proof_sent` threads were read by hand and all seven were placed correctly. The remaining
classes have not been hand-checked yet, so treat their counts as right to within a few threads,
not to the unit.

## The histogram (every thread in exactly one class, sums to 417)

| Why it did not close | Threads | Share | What is in it |
|---|---:|---:|---|
| **No read tool** | **146** | 35.0% | proof sent 121, where is my request 14, claim start 4, plaque order 3, what is needed 2, why declined 1, claim code added 1 |
| **Guard refused her own reply** | **60** | 14.4% | `contradict/fact_unverified:status_chase` 56, timeframe promise 2, staff name 1, score/signal 1 |
| Resolved by Caroline | 58 | 13.9% | answered, nothing left waiting, no earlier promise open |
| No reply from anyone yet | 43 | 10.3% | 24 waiting six hours or more, 19 under six hours |
| Needed a human decision or action | 39 | 9.4% | connect a Spotify/Tidal artist link 24, merge 3, GDPR erasure 3, claim conflict 3, credit wrong 3, track fix 2, refund dispute 1 |
| **Answerable, handed off anyway** | **37** | 8.9% | product question 14, other 11, how to add a credit 6, billing question 3, profile edit 2, app bug 1 |
| Answered, not closed | 19 | 4.6% | answered while an earlier promise of a person is still open 15, customer wrote again 3, refused with a reason 1 |
| Nothing to resolve | 15 | 3.6% | robot mail and bounces 14, empty thanks 1 |

## The three causes to fix

1. **No read tool: 146 threads (35%).** In 121 of them the customer sent proof. Caroline's
   reply is the approved thank-you line ("everything you send here is recorded against your
   account and your open requests and goes to the verification team") followed by "I'm pulling
   in a teammate to take this from here." The first sentence is the answer. The second is a
   promise nobody keeps: no person is assigned and no person replies. Outside the
   guard-blocked threads, that one sentence was sent 256 times in the window.
2. **The guard refused her own reply: 60 threads (14%).** 56 of the 60 are one rule. She sends
   the approved status line ("your request is in the verification queue"), the guard requires a
   code-sourced fact that the customer has an open request, and no caller ever supplies that
   fact (`plugins/intercom/src/channel.ts` calls `guardOutbound` without `facts`), so the line
   is blocked every time. She is never told why and cannot retry.
3. **Answerable, handed off anyway: 37 threads (9%).** Product, billing and how-to questions
   that need no account state and no decision, where she still said a person is coming.

Together these are 243 of the 359 threads that did not resolve (68%).

## What this report does not claim

- It does not say which of the 43 unanswered threads would have resolved; 19 were under six
  hours old when read.
- "Answerable, handed off anyway" is the class most exposed to the regex: it is defined by
  what the customer asked, not by a check that her knowledge base holds the answer.
- No customer text, name or address is in this file. The masked corpus used for the read is
  scratch on the worker box and is not committed.

---

# What this branch changes, with before and after

## Read this first: none of it is live yet

Every "after" below is either a replay over the same 417 conversations or a tested mechanism.
There is no live "after" number, and there cannot be one until the branch is merged and deployed.

Deploys to node-8 are also blocked right now, for a reason outside this branch. Read 2026-11-12
04:40Z:

- node-8 runs commit `87027e740` (2026-11-09). `main` is 11 commits ahead of it.
- The last three deploy runs failed. The latest
  (https://github.com/Muso-AI/hydra/actions/runs/43152336573) stops at "DEPLOY BLOCKED: server and
  repo both changed these paths since 87027e740".
- So "no conversation is assigned to a person by default" (#1889, merged 01:40Z) is not running
  either. The guard ledger rows written at 03:52Z still say `assignment: team_inbox` and answer
  bank `2026-11-01.4`; the repo is at `2026-11-11.1`.

The daily line (below) is how the live "after" gets read, on the same measurement as the 58 of
417, once a deploy lands.

## Cause 1. No read tool: 146 conversations

| | |
|---|---|
| Before | Caroline could not read the customer's own request or claim state: every read tool was denied. 146 of 417 conversations did not close for that reason. |
| Change | `credit_verification_check` and `profile_claim_status` are allowed. Both fail closed unless the conversation has a signed-in contact (a user, with an account id, older than 24 hours), return that customer's own rows only, and write nothing. Nothing typed in the conversation selects an account. Doctrine teaches them as "the one read". |
| After | Not measured. It needs the deployed agent. |

Three things that were asked for and are not in this change:

- **`profile_credits_status` stays denied.** It does not fail closed, it looks up any profile
  typed in the conversation, and it scans for same-name duplicates. That is the look-up and
  dedupe work the captain kept away from her on 2026-10-28.
- **Order state was already hers.** `order_lookup` was never denied. Three of the 146 are plaque
  orders, so this is a doctrine gap, not a missing tool, and it is not fixed here.
- **This narrows a captain ruling.** The 2026-10-28 ruling was "hand off only: she looks nothing
  up". Two read-only tools now sit outside it, because the brief for this work asked for request,
  credit and claim state. Every tool that verifies, claims, merges, dedupes, removes or files
  proof is still denied (exec plus 12).

## Cause 2. The guard refused her own reply: 60 conversations

| | |
|---|---|
| Before | 63 refusals on 60 conversations in the day. 59 of the 63 were one rule: the approved status line needs a measured "this customer has an open request" fact, and no code ever supplied it. She was told nothing, could not retry, and the customer got the fallback line. Refusals explained to her: 0. Corrected on retry: 0. |
| Change | (a) The two reads above now write that fact, and the guard reads it, for this message only. (b) A refusal goes back to her as a fixed reason per rule and she writes the reply once more. The retry passes the same guard before anything is sent. One retry, a constant. No retry on a leaked canary or a classifier block. |
| After | Proven end to end in tests through the real webhook route (refused, explained, corrected reply is what the customer gets; refused twice, fallback once and one page). Live count: not measured. The daily line prints refusals explained, corrected on retry, and ended on the fallback line. |

The guard is not relaxed. The retry is a second attempt at the same bar.

## Cause 3. Answerable, handed off anyway: 37 conversations (and the promise in 268)

| | |
|---|---|
| Before | She told 268 of 417 customers a person was coming. A person was assigned in 63 and replied in none. The sentence was almost always added after a complete answer. |
| Change | A promise of a person in a reply she wrote is removed before sending: she cannot assign a conversation, so it is false every time. Only removal; what is left is what she wrote and still passes the guard. A reply that was nothing but the promise is not sent: she gets the reason and the one retry. Doctrine no longer tells her to end on that line. |
| After (replay) | Replayed over the day's 780 replies: the sentence comes out of 370 (15 distinct wordings, each read by hand, none an honest statement). 70 replies were only the promise. Conversations left on a promise of a person, not counting the 60 the guard refused: 208 before, 40 after. |

Replayed on the daily measurement, same 417 conversations:

| Outcome | Before | Replay |
|---|---:|---:|
| Resolved | 58 (13.9%) | 92 (22.1%) |
| Promised a person, nobody assigned | 205 | 37 |
| Promised a person, assigned | 3 | 3 |
| On a queue line | 17 | 123 |
| An earlier promise still open | 15 | 40 |
| Guard fallback | 60 | 60 |
| No reply | 48 | 48 |
| Customer wrote again | 10 | 10 |
| Refused | 1 | 4 |

How to read that table:

- **The replay only removes a sentence.** It cannot show what the read tools or the retry would
  have added, so the 60 guard conversations and the 48 unanswered ones do not move.
- **Most of the promise becomes a queue line, not a resolution.** 106 conversations move to "it
  is with the verification team". That is honest, and it is still a customer waiting. Removing
  the promise does not close conversations. The reads are what can.
- **34 conversations become resolved.** 16 from cause 1, 10 from cause 3, and 8 where the customer
  asked for something that needs a person's decision (a Spotify or Tidal link, a wrong credit, a
  claim conflict, an erasure, a track fix). Those 8 read as resolved because what she wrote, less
  the promise, is an answer. They were not read by hand. Treat 92 as an upper reading.
- The 37 still promised a person are 3 merge conversations (left to the merge guard on purpose)
  and, mostly, replies that end on the approved timing line "you'll hear from us in this
  conversation and by email".

## The daily number

`scripts/support-resolution-daily.py`, one line to `#clio_devops` at 06:30 UTC
(`docs/support/resolution-daily.md`). Read-only on Intercom. Re-reading the baseline window from
the live inbox with it gave 58 of 417 again, so the daily number and this report were the same
measurement.

**The daily line's baseline is now 63 of 417 (15.1%), not 58.** A later review found the count
kept a conversation waiting on a queue line even after a later message had answered it. Corrected
(rules `asq-2026-11-12.5`), the same 417 conversations read 63 resolved: three got a "your credits
were approved" notice after the queue line, one a "your requests were closed, you can reopen them"
notice, one a question back to the customer. Nothing in the inbox changed between the two reads.
Every other number in this report (the histogram, the replay) was read under the earlier rule and
is left as it was measured. Compare a new day with 63, the baseline the line prints.

A conversation is not resolved when nobody replied, when the customer wrote last, when a person
was promised or assigned, when it was parked on a queue or holding line, when the guard's fallback
line went out, when she refused, or when an earlier promise of a person is still open. Closing a
conversation does not resolve it.

It also prints the whole-inbox count of conversations where the customer wrote last. Read
04:36Z: 1,645, of which 1,620 have waited more than seven days.

**One trap already caught.** Between 01Z and 03Z on 2026-11-12 another lane
(cs-systemic-issues-lane-c1) posted its approved holding message ("your message is here and it
will be read") as Caroline to conversations nobody had answered. Counted as answers, the day read
106 of 426 (24.9%) with nothing deployed. They are holding lines, not answers: the measurement
now says so, and the same hour reads 64 of 425 (15.1%). The baseline is unchanged by that rule
(58 of 417). Any new bulk sender's wording has to be added the same way, or it will read as
resolutions.

## Not done

- No live before/after for any of the three causes (see the top of this section).
- The 43 conversations with no reply at all were not investigated. 24 had waited six hours or more.
- 39 conversations need a person's decision. Nothing here routes them to one; the hand-off was a
  promise with nobody behind it before, and it is now an honest queue line with nobody behind it.
- The whole-inbox backlog (1,620 conversations waiting over seven days) is counted, not worked.
