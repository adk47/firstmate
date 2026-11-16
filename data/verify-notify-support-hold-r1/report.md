# The verify notes: a support@ contact is asked, never held (2026-11-15)

**What was wrong.** `credit_review/verify_notify.py` held a note for every user listed in the
proof export's `gmail_contacts_90d` (anyone who emailed support@ in the last 90 days) — firstmate
050's rule, "when in doubt, don't send". The hold had no owner and no queue: the credit kept its
verdict on the send side, nothing was closed, and the user was offered again on every later run
(verify ledger `deferred_pending_doc` rows) that nobody works. So a person who wrote to support@
and was then approved a credit got no note at all — silence, not an ask and not a no.

**What changed.** The same list stops holding on the send side, exactly as the decider dropped it
on 2026-11-14 (PR #1992, `data/support-contacted-hold-r1/report.md`): a support@ contact is decided
like anyone else, so the note is an ASK, and nothing is withheld because they wrote to support@. No
copy changed; nothing is sent by this PR.

Three hold sites went: `drop_documented` (past credits), `screen_live`'s `if ask and
is_support_contact(...)` branch (new credits), and the waiting set in `removal_due`. The
`Report.support_contact_users` / `support_contact_credits` counters and their line in the daily
render are gone with the branch (`render()` no longer claims anyone is held for it).

**What deliberately stays.**

- The list is still READ and still has to be readable: `load_proof_on_file` still raises
  `ProofFileError` when the export carries no fresh `cs-gmail` snapshot ("anyone may have emailed
  support@"), and that still halts the run. Only the hold it used to imply is gone.
- `ProofOnFile.support_contacts` and `is_support_contact()` stay: the lanes that still own a hold
  on the same list read it through them — `credit_review/claim_proof_ask.py` (the `proof-need-ask`
  sender, ticket **`support-hold-sender-lift-r1`**), plus `uvn_status` and `score_approve` behind
  their own scoped holds. `scripts/intercom-backlog/tail_lists.py` only counts the listed accounts
  for its report line; it holds nobody. Lifting the live hold is its own ticket, not this PR.
- The documents gate is untouched: a user with ANY proof-on-file entry is still not asked (a
  `pending_doc` is still asked once, after the review).

## Measurement

Host node-8, ledger `/var/lib/hydra/credit-review/ledger.sqlite3` (mtime 2026-11-16 03:59Z), proof
export `/var/lib/credit-trust/proof-on-file.json` (`generated_at` 2026-11-16T03:58:28Z, 692 accounts
on the list), deployed sha `0b51a5b5a9`, measured 2026-11-16 04:05–04:20Z. Reproduce with
`data/verify-notify-support-hold-r1/tools/measure_hold.py` (read-only: the ledger is opened
`?mode=ro`, `AdminClient` refuses anything but a GET; the snapshot it writes holds customer ids and
stays on the node, never in this repo).

### 1. The run's own window: 1,195 candidate rows, 314 profiles, 637 admin GETs

`snapshot`, then `counts` against the deployed tree and against this branch. `counts` composes its
hold through three gates in `run()`'s own order (`screen_live`, then `hold_affiliated`, then
`hold_recently_asked`), not through `drop_documented`, which is not on that path; the identity and
cap holds `run()` applies after those three are not measured. `max_users` is not reached — the
counts are computed before the day's cap.

| | support@ branch held (accounts / credits) | held **only** for having emailed support@ (accounts / credits) | accounts on the list | their credit rows |
|---|---|---|---|---|
| **before** (deployed `0b51a5b5a9`) | **3 / 6** | **0 / 0** | 3 | 6 |
| **after** (this branch) | — (the counter no longer exists) | **0 / 0** | 3 | 6 |

Both rows are a run of the shipped tool on the same snapshot: `counts --snapshot /tmp/fm-hold-rows.json
--scripts /opt/hydra/scripts` for the deployed tree and `--scripts <this branch>` for the after row.
The deployed tree's `run_gates` block reads `held_by_the_documents_gate 387`, `held_by_affiliation
250`, `held_by_the_re_ask_lock 177`, `documented_users 36`, `pending_doc_users 42`; the branch's
reads the same except `pending_doc_users 45` — the three listed accounts move from the support@
branch to the documents branch, which is where they were going to be held anyway.

So the branch **did** fire on today's data — 3 accounts / 6 credits — and every one of those
accounts has a proof-on-file entry, which is why `held_only_for_support_contact_*` is 0 on both
trees: no account was held *only* for the list. The earlier composition of this tool reported 0 / 0
for the before row because it ran `drop_documented` first, and that function deletes every row of
any account with a proof-on-file entry before `screen_live` — and so the support@ branch, which is
tested **first** in the deployed tree — ever sees it. That 0 was structural; the 3 / 6 above is the
measured value.

What the change does and does not move: the documents gate is untouched, so an account with a
proof-on-file entry is held on every run exactly as before; only a listed account with no entry at
all moves from "held for the list" to the note the ladder's verdict calls for. Nothing here turns
an "asked" into a "held".

### 2. What PR #1992 brings to this step (`decider-hold` — ledger only, no admin call)

The decider's own support@ hold, newest decision row per request: **649 requests / 47 users**, every
one of them a `hold` (never approved, so this step never saw them at all — which is #1992's half of
the problem).

| of those 47 users | users | requests |
|---|---|---|
| have a document on file → still held, by the **documents** gate (unchanged) | 46 | 414 |
| no document at all → held **only** by the support@ list | **1** | **235** |

So after #1992 moves those rows onto the ladder, the sender-side branch would have silently re-held
1 account and its 235 requests. With this change that account gets the note the ladder's verdict
calls for (an ask), and the other 46 are untouched — their hold is the document they sent, which
nobody is arguing about.

### Why not more

Today the branch has no other victims: of the 1,541 approved decision rows in the live ledger, 6
rows across 3 accounts belong to users on the list, and all 3 have a document on file. The two
populations above are the whole of it — 0 accounts now, 1 account behind #1992, 46 accounts the
documents gate owns.

**The population is still held by another sender, and this PR does not reach them.**
`credit-trust-verify-notify-15m` is `enabled: false` (retired 2026-11-06), and the sender that
actually runs for these users is `claim_proof_ask.py:402` (`if str(uid) in support_contacts:
_support_held(...)`), the `proof-need-ask` family of the outbound tick. Lifting that hold changes a
different campaign's audience, so it is filed as **`support-hold-sender-lift-r1`** — the same split
PR #1992 recorded. This PR is the `verify_notify` half only.

**The brief's 69 users / 954 requests is an estimate; the measurement above replaces it.** 954 was
the count of ledger rows carrying the decider's support@ reason on 2026-11-14 (PR #1992's report);
the live population today is 649 requests / 47 users on the newest row per request, of which 1
account / 235 requests has no document on file and 46 accounts are held by the documents gate.

## Tests

`scripts/tests/test_credit_verify_notify.py` (207 tests, OK):

- `test_a_support_at_only_contact_is_asked_like_anyone_else` — a listed account with no document
  gets its note, nothing is deferred, and the render no longer claims a support@ hold. (It replaces
  `test_a_support_at_only_contact_gets_no_note_and_is_held`, which asserted the silence.)
- `test_a_user_off_the_support_list_is_unaffected` — a user with a `pending_doc` is held and
  deferred exactly as before, listed or not: the documents gate is not weakened.
- `test_a_support_at_contact_is_not_dropped_from_past_credits` — `drop_documented` no longer drops
  a listed account; its row is routed by the same gates as anyone else's.
- `test_a_support_at_contact_reaches_the_removal_export_instead_of_a_hold` — a past credit for a
  listed account whose sent windowed note named a reply-by date is **removal-due**, while a user
  whose document is waiting for review stays `HELD_AWAITING_REVIEW`.
- `test_a_stale_support_contact_snapshot_sends_nothing` (unchanged) — the list still has to be
  readable, or nothing is sent.

## Docs

`docs/credit-verification/verify-request-notes.md`: the enable-gate table no longer lists the 90-day
support@ list as a gate, and the paragraph under it says what the list still does (a readable
snapshot is required; `claim_proof_ask` owns the live hold on it).

`docs/credit-verification/credit-trust-decide.md`: the sentence PR #1992 added ("`verify_notify`,
`claim_proof_ask`, `uvn_status` (stale Gmail part) and `score_approve` each still hold a support@
contact") no longer lists `verify_notify`, and names `support-hold-sender-lift-r1` as the owner of
the `claim_proof_ask` hold. #1992 is in this branch's base (the pipeline rebased onto it), so the
correction is made here rather than left to a follow-up.
