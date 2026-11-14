# Per-gate counts, whole list: uvn-status-paid and r1-free

Read 2026-11-13 21:46-21:49Z from the tick's own pre-check artefacts on node-8
(`/root/h2-runs/sched/<tick>/<family>-<segment>-check.{out,json}`). No store was scanned: every number is
either a counter the pre-check printed in `check.out` or a `jq` tally of that check's `outcomes` array
(`tools/gate.jq`, at most 595 rows per file). All ticks below ran deployed sha `5e2765d4`.

A check walks one PAGE of the list (`page.start..page.end`, raw list entries), so a whole list is one
rotation of the cursor. The lists are rebuilt every tick, so the pages of one rotation come from lists that
differ by a few entries.

Two things the printed line hides, both read from the code:

- `deferred (messaged in the last 7 days or today)` is `report.deferred_users`, and every gate deferral
  (rc 3) is added to it (`verify_notify.py` `send_all`, `report.deferred_users += 1`). So that line
  INCLUDES `deferred by the gate at send`. The ledger's own 7-day deferral is the difference.
- A user whose every listed request is on the approval path or already on the profile leaves as
  `nothing_to_ask` (`uvn_status.plan`), which has no user counter in the printed line (only the request
  counts). That row below is the remainder of the page and is marked as inferred.

## uvn-status-paid: 947 entries walked, 1 would be messaged

Pages: `20261113T2005Z` 0..695 of 923 (0 accepted) and `20261113T1800Z` 693..945 of 950 (1 accepted).

| gate | 2005Z | 1800Z | total | source |
|---|---:|---:|---:|---|
| documents on file (not asked) | 433 | 47 | 480 | check.out |
| gate: `c2_signed_only` (class C, `--no-correction`) | 116 | 17 | 133 | outcomes |
| `nothing_to_ask` (approval path / duplicate), inferred | 5 | 102 | 107 | remainder |
| already handled (noted before, or documents received) | 62 | 5 | 67 | check.out |
| 7-day note cooldown, from the ledger before the gate | 39 | 17 | 56 | check.out minus outcomes |
| gate: `core_notice_within_7d` | 10 | 19 | 29 | outcomes |
| gate: `messaged_7d` | 1 | 17 | 18 | outcomes |
| gate: `comm_state` (account hold and siblings) | 2 | 15 | 17 | outcomes |
| held by the fraud lens | 7 | 7 | 14 | check.out |
| held: blank or unshowable title, artist or role | 9 | 2 | 11 | check.out |
| 90-day re-ask lock (`recently_asked`) | 4 | 0 | 4 | check.out |
| gate: `no_channel` | 3 | 0 | 3 | outcomes |
| refused: G5 (a field carries a link, an address or markup) | 1 | 1 | 2 | outcomes |
| refused: more than 1,000 credits in one note | 1 | 0 | 1 | outcomes |
| gate: `inapp_not_armed` | 0 | 1 | 1 | outcomes |
| held: owed requests changed since the list was built | 0 | 1 | 1 | check.out |
| excluded today (another lane) | 1 | 0 | 1 | check.out |
| unmeasured (`gate_timeout`) | 1 | 0 | 1 | outcomes |
| would be messaged | 0 | 1 | 1 | accepted |
| **total** | **695** | **252** | **947** | |

No outcome names a copy verdict, the one-per-day limit or the owing-builder class.

## r1-free: 818 of 902 entries walked, 0 would be messaged

Pages: `20261113T1800Z` 0..417 of 873, `20261113T1854Z` 417..617 of 902, `20261113T2005Z` 617..818 of 902.
Entries 818..902 (84) were not walked by any check on file at 21:49Z.

| gate | 1800Z | 1854Z | 2005Z | total | source |
|---|---:|---:|---:|---:|---|
| gate: `r1_receipted_in_thread` (already acknowledged in the thread) | 48 | 135 | 118 | 301 | outcomes |
| already handled (noted before, or documents received) | 230 | 4 | 3 | 237 | check.out |
| refused: `r1_filing_class_unknown` (payload has no `filing_muso_ui`) | 74 | 15 | 18 | 107 | outcomes |
| 7-day note cooldown, from the ledger before the gate | 13 | 4 | 19 | 36 | check.out minus outcomes |
| refused: `r1_unreadable_filing` | 14 | 12 | 10 | 36 | outcomes |
| held: big-track rows, document ask only | 15 | 7 | 13 | 35 | check.out |
| gate: `core_notice_within_7d` | 4 | 11 | 15 | 30 | outcomes |
| held by the fraud lens | 8 | 3 | 1 | 12 | check.out |
| refused: filing read as a screenshot of Muso | 3 | 4 | 2 | 9 | outcomes |
| held: blank or unshowable title, artist or role | 3 | 1 | 1 | 5 | check.out |
| refused: G2 (thread has more than one contact) | 1 | 2 | 0 | 3 | outcomes |
| refused: G5 (a field carries a link, an address or markup) | 1 | 2 | 0 | 3 | outcomes |
| refused: Intercom identity | 2 | 0 | 0 | 2 | outcomes |
| gate: `comm_state` | 1 | 0 | 0 | 1 | outcomes |
| unmeasured (`gate_timeout`) | 0 | 0 | 1 | 1 | outcomes |
| would be messaged | 0 | 0 | 0 | 0 | accepted |
| **total** | **417** | **200** | **201** | **818** | |

No outcome names the 90-day lock, a copy verdict, the one-per-day limit or the owing-builder class.

## Commands

```
# pages and outcome totals per tick
jq -c '{page, max_users, n: (.outcomes|length), acc: (.accepted|length)}' <tick>/<family>-<segment>-check.json
# the printed counters
head -1 <tick>/<family>-<segment>-check.out
# outcomes per gate
jq -r -f tools/gate.jq <tick>/<family>-<segment>-check.json
```
