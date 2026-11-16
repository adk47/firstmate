# Item 4: precedent conflicts, measured

Read 2026-11-15 16:58Z to 17:01Z on core's replica from node-8, read only. This note
is a measurement. It changes no code.

## Two different things carry the word "precedent"

**The drain's refuse precedent is the claimant's own earlier refusal.** The key is
claimant, track and exact role set (`scale_drain.claim_key`), so one account's
decision never reaches another account's request. A pending request with a refuse
precedent is planned `cannot_confirm` / `precedent_refuse`, and newer evidence sets
the refusal aside.

**A conflict is another account's approved credit for the same role on the same
track.** The drain has no such rule. It lives in the credit-precedent gate, which is
not in git: `main` has no `scripts/credit_precedent/`. What runs is `/root/prev2.js`
on node-8 (99 lines, dated 2026-11-11), copied into a core-backend pod and run with
`--apply` every 15 minutes by `credit-precedent.timer`. It writes core directly: it
sets `status='approved'` on the requests it passes, and it drops and recreates its
working tables in core's database on each run. In the last 26 hours every one of its
101 runs excluded every eligible request as a conflict (565 of 565 at 16:59Z) and
approved nothing.

https://github.com/Muso-AI/hydra/pull/1971 (another lane; open, 42 commits behind
`main`, with merge conflicts as of 17:00Z) adds that script to git and changes the
rule.

The first review of the no-humans patch described `precedent_refuse` as the second
thing. On the data they are nearly disjoint.

## The pending requests, by both

102,016 pending requests read (8,304 users). 1,438 rows on those tracks were dropped
because their credits or user could not be read.

| | no other account approved | another account approved, role several people can hold | another account approved, one-person role |
|---|---|---|---|
| no own refusal | 95,359 | 3,694 (958 users) | 1,797 (339 users) |
| own earlier refusal of this claim | 1,014 (204 users) | 145 (31 users) | 7 (7 users) |

- The drain's refuse precedent covers 1,166 requests. For 1,014 of them no other
  account holds the credit. The line "this credit is currently attributed to another
  verified profile" would be false for those.
- 5,643 requests conflict with another account's approved credit. The drain has no
  conflict rule, so it plans all of them on its other rules; 152 also carry the
  claimant's own earlier refusal. I did not read from a plan what it decides for any
  of the 5,643.
- These counts are over every pending request. The running gate looks only at the
  requests it could approve (a trusted user, three or more earlier approvals, in
  `user_verification_needed`): 565 today.
- "One-person" is `roles.ONE_PERSON_FAMILIES`: mix, remix, master, immersive mix,
  immersive master, remaster. 1,804 of the 5,643 share one of those. The other 3,839
  share only roles such as producer, engineer, writer, assistant or performer.

A second read keyed on the Spotify track id, as the gate keys it, gave 5,672
conflicts (3,861 and 1,811), and 758 more requests where only another account's
pending request shares a role. Of the 5,672, 4,174 have one approved holder, 999
have two, and 499 have three or more.

## Against the four conditions

| condition | the gate running on node-8 | PR 1971 | the drain |
|---|---|---|---|
| never while the holder is pending | a holder in `user_verification_needed` blocks, as an approved one does | only an approved holder blocks | no conflict rule |
| the reason is `role_already_credited` | none recorded: a count in the run's log | `credit_approved_for_another_user` | not applicable |
| a role several people can hold is no conflict | no split: any shared credit blocks | no split: 3,839 of 5,643 would be blocked | not applicable |
| the line never says "rejected" and names no other party | no line | a line is owed, with no sender (`BLOCKED_OWED_LINE_NO_SENDER`) | no line |

The node-8 column is read from lines 40 to 99 of `/root/prev2.js` and its journal.

## What follows

- Item 4's code is not in the drain. The three open conditions (the reason's name,
  the one-person split, the copy) are changes to PR 1971's rule and to the
  `credit-approved-elsewhere` line in `need_asks.py`. Two lanes editing that rule
  would collide, so this lane has changed nothing there.
- The drain's `precedent_refuse` needs its own line, and it is a different one: the
  earlier refusal was of the same person's same claim.
- The captain's ruling quoted in PR 1971 says the blocked requests must be decided
  and told. The review's condition says a role several people can hold is not a
  conflict. Both hold if the 1,804 one-person rows get the line and the 3,839 others
  go through the ladder like any request. That reading is mine; nobody has ruled on
  it.

## Not measured

- Whether the approved holder's credit is itself sound. An approval is counted as
  it stands.
- Roles were compared as exact strings, as the gate compares them. "Mixing Engineer"
  against "Mix Engineer" is not a shared role here.
- PR 1971's own before and after, which is in its report. I read its diff and
  description and ran none of it.
- Lines 1 to 39 of `/root/prev2.js`, which build its trusted-user and hold tables.
- Whether the file PR 1971 adds started from the one running on node-8. Their
  hashes differ.

Kept on node-8: `/tmp/nh-n1-measure/keep/i4/q1.out`, `q2.out`.
