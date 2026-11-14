# Proof marker: the post-merge fix and the one-off reconcile, 2026-11-13

A review after #1942 merged found the marker's tag was narrower than `verify_ledger.mark_tagged`'s, the writer
it replaces. Three gaps, measured on the node-8 ledger at 16:02Z before anything was changed:

| gap | what `mark_tagged` writes | what rule `pm-1` wrote | exposure on node-8 at 16:02Z |
| --- | --- | --- | --- |
| rejected verdicts | cleared under the note's family and under the note of every credit it names | cleared under the first note only | 102 of 585 marked notes name credits that live under another note; `verify_proof_reviews` holds 0 rows, so nothing had been left rejected yet |
| family | every row of the family is tagged | the one row | 0 follow-up rows exist (all 13,053 sent rows are first notes), so no sibling was left untagged yet |
| attachment count | `proof_attachments` | left at 0 | 585 of 585 |

Both zero rows are "not yet": the first review recorded, or the first reminder sent, would have met the gap.

## What was done

1. 16:01Z: the marker loop on node-8 was stopped and `/etc/hydra/proof-marker.disabled` written, so the merged
   hourly cron cannot run rule `pm-1` after a deploy. node-8 was on `5e2765d4`, which has no `proof_marker.py`:
   the merged cron had never run. The seven runs were this lane's, from a scratch copy.
2. The fix (rule `pm-2`): a tag now writes all three, in one transaction, and `revert` puts all three back.
   `verify_ledger.proof_families` is the one place the family set is built; `mark_tagged` calls it too.
3. `proof_marker.py reconcile`, from a scratch copy of the fix commit `c7b1b8bc7` (`/root/proof-e1b`).

## Reconcile counts (node-8 ledger)

| | dry run 16:31:26Z | applied 16:31:58Z | dry run after |
| --- | --- | --- | --- |
| standing marks | 585 | 585 | 585 |
| tag changed since the mark (left alone) | 0 | 0 | 0 |
| attachment count to fill | 585 | 585 filled | 0 |
| follow-up rows to tag | 0 | 0 | 0 |
| rejected verdicts to clear | 0 | 0 | 0 |
| verdicts newer than the document (never cleared) | 0 | 0 | 0 |
| marks moved to rule `pm-2` | 585 | 585 | 0 |

Marks by run: `pm-20261113T123401Z` 534, `T131320Z` 18, `T134321Z` 7, `T141321Z` 3, `T144321Z` 2, `T151321Z` 5,
`T154321Z` 16. Read back after the apply: on all 585 notes `proof_attachments` equals the mark's document count
(1 on 241 notes, 2 on 142, 3 on 81, up to 44 on 2) and `proof_tagged_at` is unchanged; 688 rows carry a tag,
as before (585 from the marker, 103 from the 2026-11-09 backfill, which already carried a count).

The request named 672 tags. That was the tagged-row count at 15:28Z; one more run (16 tags, 15:43Z) landed before
the stop, and 103 of the tagged rows are not the marker's.

## `conversation_id` is not written, on purpose

`mark_tagged` also writes `conversation_id`. The marker does not, and the reconcile did not fill it:

- on a note, that column is the thread the note was sent in; empty means "sent by email"
  (`verify_ledger.nothing_needed_overlap` returns `by_email` for it and a correction is routed accordingly);
- the marker knows the document's conversation, not the note's: 572 of the 585 marked notes were sent by email
  and have none; of the 13 that have one, 9 equal the document's conversation and 4 do not.

Writing the document's thread onto 572 emailed notes would make a correction to them claim it went in-thread.
The document's conversation stays in `proof_intake`, reachable through `proof_marks.intake_id`.

## Undo

`proof_marker.py revert --run-id RUN` undoes a run whole (tag, attachment count, follow-up rows, cleared
verdicts). The rows as they stood before the reconcile are in `/root/proof-e1b/reconcile-prestate.json` on node-8.

## Still held

`/etc/hydra/proof-marker.disabled` stays until the fix is merged AND deployed. Removing it earlier lets a deploy
of `main` run rule `pm-1` hourly.
