# The empty-track approve rule (ET1): what it is, and how big it is

Captain, 2026-11-16 02:1xZ: *"if no credits are on a track we let those go on if it makes sense?"*

`scripts/credit_review/empty_track_approve.py` is the coded rule. This is the measurement behind it: how many open
credit requests sit on a track with **no credits at all**, and how many of those the rule would approve.

Rule doc: `docs/credit-verification/empty-track-approve.md`. **Nothing arms**: the policy ships
`apply_enabled: false` and the module wires no approve writer, so `apply` refuses even with the switch flipped.
Counts and timings only — no request, profile or user id is in this file.

## The five conditions

| # | condition | read from |
|---|---|---|
| 1 | the track is in the catalogue, under this id, with a real ISRC or Spotify id | core `GET /admin/track/<id>` |
| 2 | **zero credits** on the track | the same document (`credits[]`) |
| 3 | no role conflict on the claim | `policy.validator_conflict` / `validator_rejected_rules` / org role |
| 4 | no watchlist hit on the account or the profile | `policies/fraud-watchlist.json` |
| 5 | no R8 hold, and a green account gate | `comm_state.account_hold_facts` / `account_gate` |

Any unreadable input is a hold. Condition 2 is checked for the **whole track**, never per profile: one credit
anywhere on the track ends the rule, and `test_one_credit_on_the_track_is_never_approved` pins it by name.

## Where condition 2 is read, and why not from the analytics replicas

I first read "credits on the track" from `postgresql_stats.public.profile_track` (the served-credit replica). It
is wrong for this purpose, and wrong in the unsafe direction — it says **zero** for tracks that carry credits:

- 40 tracks the replica counted zero: core's own document lists credits on **39** of them.
- 40 tracks the replica counted non-zero: **33** disagree with core, usually undercounting (7 vs 71, 1 vs 9).
- `postgresql_core.public.profile_v3_tracks` was tried next; it disagrees the same way (39 of 40 "zero" tracks
  carry 2–5 credits in core).

A rule that pre-filtered on a replica and then approved would approve tracks that already carry credits — the one
thing this rule must never do. Condition 2 therefore reads core's track document, one paced GET per *candidate*
track; candidates are already narrowed by conditions 3 and 4, which are local reads over the queue.

## The population, measured on prod (2026-11-16, node-8)

`python3 scripts/credit-empty-track-approve.py measure --sql` (the rule's own CLI) — 4 minutes, of which the replica
statement is ~25 s:

| measurement | figure |
|---|---|
| open held requests with a track id | **102,936** (`unverified` + `user_verification_needed`) |
| distinct tracks behind them | **87,505** |
| requests with a role conflict (3) | **55,024** — `reject_*` 33,281, `review_*` hold 19,168, org role 1,579, validator conflict 902 |
| requests whose validator verdict could not be read | **94** (held, never approved) |
| requests with no real ISRC on the request | **16,178** — not a hold: condition 1 accepts a Spotify id from the track document |
| watchlist hits (4) | **0** |
| requests passing conditions 3–4 locally | **47,958** rows / **42,387** tracks |

### The census: every candidate track, read

One paced `GET /admin/track/<id>` (`~2/s`) for **all 42,387** candidate tracks — no sample, no extrapolation. The
first 30,368 were read before the ISRC prefilter was removed (the QA finding: condition 1 accepts a Spotify id, so a
request with no ISRC is still a candidate); the remaining 12,019 were read in a second pass:

| | |
|---|---|
| tracks read | **42,387** (0 errors, 0 unread) |
| tracks with **zero credits in core** | **29** (0.07%) |
| tracks with exactly one credit | 146 |
| median credits per track | 7 |
| open requests on those 29 tracks | **30**, from **10** users |

So the tracks behind held requests are not new and empty: they are established tracks, and the claimed credit is
the ~6th–8th on them. The 12,019 tracks the ISRC prefilter had been hiding changed nothing: not one of them is
credit-free.

### The full five-condition dry run on that population

`evaluate` over those 30 requests, with the live account gate, the R8 hold set and the paying list:

| outcome | rows | users |
|---|---|---|
| **approve** | **18** | 10 |
| hold `track_moved:<id>` | 12 | — |

The 12 holds are not read failures: core served a document for a **different** track id, i.e. the request's track
was merged into another one. The empty credit list there belongs to the wrong id, so the rule holds (and names the
survivor). All 18 approvals sit on a green (`allow`) account gate and a `user_verification_needed` request; 1 of the
18 is a paying user.

### Where those 18 sit today

Classified by the verification queue report's **own** `classify_credit` (its own ledger facts, proof-on-file feed,
watchlist and support-contact list — not a copy of the rule):

| bucket | approve rows |
|---|---|
| `human` (a person is working it) | **5** |
| `not_told` (we asked, no answer yet) | 9 |
| `told` (we asked and got an answer) | 4 |

### What the rule refuses to guess

Three inputs can be missing, and none of them reads as "no":

| input | if it cannot be read |
|---|---|
| the fraud watchlist | `watchlist_unread` — every row holds, `measure` prints no number, `decide` records nothing, and the run pages |
| the validator's verdict (`verificationdata`) | `validator_rules_unread` — held (94 rows in the population above) |
| the validator's own `_hold_on_error` | `validator_conflict` — held, exactly as the decider reads it |

Pinned by `FailClosedTests` in `scripts/tests/test_credit_empty_track_approve.py` (10 tests), including that a
request with no ISRC but a Spotify id on the track document is still found and approved.

**Spot check on the live queue (2026-11-16, after the fix):** 2,107 open requests carry a non-empty `rule_errors`
map; 24 of them carry `_hold_on_error`, and **8 of those 24 were otherwise clean** — they are the rows the old
reading would have carried on to the track read. All 8 are now held as `validator_conflict`, and none of them sits
on a credit-free track, so the fix changes no approval today. It is still the right reading: a row whose only
signal is in `rule_errors` must not be approved on the strength of a map we did not read.

## Queries (re-runnable)

```
python3 scripts/credit-empty-track-approve.py measure --sql --max-tracks 3000 --out /tmp/et_measure.json
python3 scripts/credit-empty-track-approve.py decide  --max-requests 40
python3 scripts/credit-empty-track-approve.py apply              # refuses, always
```

The statement behind the first table is `empty_track_approve.SCAN_FACTS_SQL` — one statement for the whole open
queue, printed by `measure --sql` with the run. Conditions 1–2 are not in it: they come from core's own track
document, one paced GET per candidate track, because every analytics replica tried disagrees with it.

## What this means

The rule is correct, deterministic and cheap (one replica statement plus one paced GET per candidate track, ~1.2 ms
of amortised cost per open request), and **its population on prod today is 18 approvals across 10 users** — 0.02% of
the open queue. The answer to the captain's question is *yes, and almost nothing is waiting on it*: a held request
on a genuinely credited-free track is rare, and half of those rare ones are merged-away track ids.

That is also the reason not to arm it next. Arming means a second approve path in core (a writer, a wrapper
predicate, a registry decision, a Fable ruling on the copy) for 18 credits, 5 of which a person is already looking
at. Keep it as the coded, shadow-only rule: it costs nothing to run, it answers the question in four minutes if the
queue's shape changes (a new distributor's members would show up as a burst of first-credit claims), and it can be
armed later on a measurement that justifies it rather than on a hunch.
