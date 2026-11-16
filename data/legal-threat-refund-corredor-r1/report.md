# Refund and analytics verification: ClickUp 869da8wkd / Intercom 215474146713878

Read 2026-11-12 ~02:15Z. Every figure below is from the system of record named beside it, not from the thread.
Nothing has been written to Stripe, Intercom, ClickUp or the profile by this lane.

## Status

| Item | State |
|---|---|
| Billing, prior refunds, analytics verified | done |
| Firstmate decision (inbox 001, 2026-11-12T02:32:51Z) | refund the $25.00, keep the subscription, then message him |
| Machine-approval path | built and tested on this branch (`scripts/muso-stripe-write.sh --machine-approval`), **not deployed** |
| Refund | **executed: no.** No transaction ids. It is **not** on the machine path: the customer's 05-17 legal-action sentence puts it on Aaron's, and the wrapper refuses a record that says `legal_threat: true`. Both approval records stay staged (not applied, not deleted), marked awaiting a fresh case-specific authorization from him - he answered on 2026-11-15 that the wall does not move |
| Product fix | no fix needed today: the served numbers are moving (cube computed 2026-11-12T01:29Z, +10.9M streams in 7 days). The store behind them has a snapshot for 163 of the 164 days since 2026-06-02, not every day; cause and dates of the freeze stated below |
| Customer message | **sent: no.** It is the acknowledgement only - no figure, no promise - so it does not wait on the refund. It is held by its own copy gate: no approved copy verdict exists for these exact bytes |
| ClickUp / Intercom | left as found (ClickUp `to do`; Intercom closed, last updated 2026-10-21) |

This change delivers the verification and the reviewed machine-approval path. It does not claim the refund or the customer
message. The refund is Aaron's to authorize (section 2), so it does not run through this path. The message is **two
messages with two separate gates**: the acknowledgement promises no figure and does not wait on the refund, and the
money message that states the amount is a second message sent only after a refund has executed (section 3).

### Why the refund did not run tonight

The decision asked for two things in order: add the machine path to the gate, then refund through it. The first is a
change to a money control, and on this branch it is unreviewed. Running this branch's copy of the gate against live
Stripe before it is reviewed would be this lane approving its own change to the control and then spending through it,
and a Stripe refund cannot be taken back. So the branch stops at "ready" for the path itself.

Two things in the decision I did differently, and why:

- **The legal-threat wall stays where it is.** `skills-all/muso-refund-processor` reserves a refund on a legal-action
  threat for Aaron by name, and this customer wrote one on 05-17. A firstmate decision does not lift a wall that names
  Aaron, and no ruling of his own that I can cite lifts it for this class, read as it actually reads: the 2026-10-30
  entry is firstmate taking option (b) with his own aside "(state this back; he may correct)", so it is not him saying
  it back; the 2026-11-12 legal-requests ruling sends only a genuine legal position to him; and the 2026-11-14
  reserved-classes ruling keeps money reserved. So the machine path refuses a record that says `legal_threat: true`,
  the two approval records stay **staged** - in the tree, not applied, not deleted - marked awaiting a fresh
  case-specific authorization from him, and the refund is Aaron's to authorize. **He answered on 2026-11-15 and the answer is that the wall does not move:**
  his instruction was "never a human" for the support path and the reviewer condition behind it is that a legal
  threat beats a refund - a refund paid after a legal threat is a settlement, not a refund, and the cap does not
  authorise it. So a within-caps refund is AI-decided *except* where the thread resolves to a legal threat, and this
  thread does: the two records stay staged and the decision whether to pay them is the one thing that goes to him.
  The customer gets an acknowledgement that takes no position, names no figure and gives no date. The escalation
  already sent is in section 5; no second one was sent.
- **Only one of the two write tools changed.** The decision asked for a machine path in the Intercom writer as well.
  One already exists for exactly this message: `intercom-verify-request.sh --campaign refund-confirm`, approved by
  `fable-ruling-1103-d2/refund-confirm`, no Slack id. Adding a second machine sender to `intercom-ops-write.sh` would
  let a firstmate record send free text to a customer, which no Fable ruling covers. See section 3 for what that
  copy can and cannot say.

## 1. Verification

### Billing (Stripe, node-8: `stripe customers list -d email=…`, `subscriptions list -d customer=… -d status=all`, `charges list`, `customers balance_transactions`, `credit_notes list`)

- Customer `cus_PHXvDGrGNsLYe1`, balance 0, not delinquent. A second customer record on his other address (`cus_OKWkLREsUGrROG`) has no subscriptions and no charges.
- **Current subscription**: `sub_1ToxJ5LsjTo3Ar3lpisLa296`, active, $12.50/month USD, started 2026-07-03, current period 2026-11-03 to 2026-12-03, not set to cancel.
- **Prior refunds: none.** No charge on the customer has `amount_refunded > 0`. No disputes, no balance transactions, no credit notes, so no live credit either.
- Paid charges in 2026, all $12.50:

| Charge | Paid | Covers | Subscription |
|---|---|---|---|
| `ch_3SqeQsLsjTo3Ar3l1oM0t8Bj` | 01-17 | 01-17 to 02-17 | `sub_1RxAXR…` (canceled 05-01) |
| `ch_3T1tCxLsjTo3Ar3l0nG9gGiL` | 02-17 | 02-17 to 03-17 | same |
| `ch_3TC2WJLsjTo3Ar3l2Td1Wvbl` | 03-17 | 03-17 to 04-17 | same |
| (04-17 renewal failed, never paid) | | 04-17 to 05-01 | |
| `ch_3TSNiALsjTo3Ar3l1XZS146e` | 05-01 | 05-01 to 06-01 | `sub_1TSNi9…` (canceled 06-29) |
| (06-01 renewal failed, never paid) | | 06-01 to 07-03 | |
| `ch_3ToxJ6LsjTo3Ar3l2TOrpxsB` | 07-03 | 07-03 to 08-03 | `sub_1ToxJ5…` (active) |
| `ch_3U0D2tLsjTo3Ar3l14N21ML7` | 08-03 | 08-03 to 09-03 | same |
| `ch_3UBRnsLsjTo3Ar3l2D2kQ3sq` | 09-03 | 09-03 to 10-03 | same |
| `ch_3UMK76LsjTo3Ar3l0nbyjIrk` | 10-03 | 10-03 to 11-03 | same |
| `ch_3UXYtQLsjTo3Ar3l25iklt55` | 11-03 | 11-03 to 12-03 | same |

### Analytics (profile `ebe8dd25-bd90-458e-a643-32b2f0cd2a68`, 17 credited tracks)

**Were they frozen: yes, from 2026-04-02 to 2026-05-07, and unreliable until 2026-06-02.**
Source: `postgresql_stats.public.track_daily` summed over the profile's tracks in `profile_track`
(`scripts/trino-query.sh`; the full series is `track-daily-evidence.csv`):

```sql
SELECT d.date, count(*), sum(d.streams), sum(d.spotify_streams), sum(d.youtube_streams), sum(d.soundcloud_streams), sum(d.views)
FROM postgresql_stats.public.track_daily d
WHERE d.track_id IN (SELECT track_id FROM postgresql_stats.public.profile_track
                     WHERE profile_id = 'ebe8dd25-bd90-458e-a643-32b2f0cd2a68')
  AND d.date >= '2026-03-01' GROUP BY 1 ORDER BY 1
```

| Date | Cumulative streams | Change | Note |
|---|---|---|---|
| 04-02 | 1,277,659,952 | +33.1M | last update before the freeze |
| 04-09 | 1,277,659,952 | 0 | identical |
| (no rows 04-16, 04-23, 04-30) | | | 35 days with no movement |
| 05-07 | 1,299,205,499 | +21.5M | first update |
| 05-21 | 1,341,168,289 | +42.0M | no rows 05-14 |
| 05-28 | 1,255,454,984 | **-85.7M** | YouTube -94.4M (the removed YouTube sources Jan described 06-02) |
| 05-30 to 06-01 | 1,259,505,492 | +4.0M over 4 days | |
| 06-02 | 1,346,288,004 | +86.8M | YouTube restored; matches the 1,346,406,403 Jan quoted that day |
| 06-03 onward | | updating, with gaps | 163 snapshots in the 164 days to 11-12: none for 06-11; total unchanged on 09-13 and 09-14; total lower than the day before on 06-30, 11-02, 11-04, 11-06, 11-07, 11-08; higher on the other 154 |

**Are they frozen now: no.** Sources: `postgresql_olap.public.cube_analytics_industry_stat_profile_view`
and `cube_analytics_profile_view` for the profile.

- Cube last computed 2026-11-12T01:29:15Z (read again at 16:57Z, same compute). Lifetime streams 1,684,479,658; last day +953,770; last 7 days +10,935,215; last month +53,497,418.
- Growth per paid month since July, from `track_daily`: 53.9M, 63.7M, 61.5M, 60.1M. Before the freeze it ran about 50M a month.
- Not every day. Since 06-02 the store has no row for 06-11, the same total on 09-13 and 09-14, and a lower total than the day before on six days (06-30 and five days in 11-02 to 11-08). "Updates daily" is not a claim this data supports; "is updating" is.
- The store is not the number he sees. On 06-05 he wrote that the figure on his profile "stays the same everyday" while the store rose on 06-03, 06-04 and 06-05. I can show the served number moving only for the 11-12 compute, so nothing here dates when his profile itself started moving again.

**Why it froze.** The daily stats store was not being written. The weekly partitions hold: `track_daily_20260416`
503,457 rows, `track_daily_20260423` 0, `track_daily_20260430` 0, `track_daily_20260507` 78,976,806,
`track_daily_20260514` 0, `track_daily_20260521` 3,408,120, `track_daily_20260528` 4,480,142
(`SELECT count(*) FROM postgresql_stats.public.track_daily_<date>`). Daily partitions start 05-29. This lines up with
the April platform migration (Athena retired 04-25, last V3 cube run 04-22) and with Jan's 05-21 "migration completed"
reply. That attribution is from the dates, not from a pipeline log I read.

**Three things on this profile that could bring him back**, none of them a freeze:

1. From 11-02 to 11-08 the daily sum went down on five days (lowest 1,639,324,280 on 11-08, with 11 of 17 tracks reporting), then recovered to 1,682,786,230 on 11-10. I did not verify whether the number he sees dipped.
2. His 3-month tile reads -48.9% against the previous 3 months. The previous window contains the 06-02 and 06-26 step restores (+86.8M, +36.4M), so the comparison is inflated, not his real trend.
3. Two of his 17 tracks have an empty title in `postgresql_stats.public.track` (`1063c407-…`, `f4b11363-…`).

### What the thread and the tickets add (Intercom API, ClickUp API)

- He first reported it 05-01 ("waiting weeks"), said "on pause for a month" on 05-04, and on 05-26 asked for exactly two months back plus two free months. The legal-action sentence is dated 05-17. His last message on the subject was 06-05. No refund was ever offered or made.
- He resubscribed 07-03 and has paid every month since. On 09-27 he opened a new conversation (215476126644638) asking how to get the live counter; Jan answered 09-28. He did not mention the freeze or a refund there.
- Three ClickUp items cover this one case: 869da8wkd, 869daw0ca (refund), 869daw0pa (contact request). All `to do`, assigned to Jan.

## 2. Refund

**$25.00: the two payments whose periods the freeze fell in, refunded in full.**

| Charge | Paid | Why |
|---|---|---|
| `ch_3TC2WJLsjTo3Ar3l2Td1Wvbl` | 03-17, $12.50 | frozen 04-02 to 04-17, 15 of the 31 days |
| `ch_3TSNiALsjTo3Ar3l1XZS146e` | 05-01, $12.50 | frozen to 05-07, then wrong or erratic to 06-01: the whole period |

- Strict pro-rata would be $18.55. I recommend the full $25.00: it is the "two months" he asked for on 05-26, and whole charges are simpler to state.
- Inside both caps: $12.50 per refund against $150, $25.00 for the year against $300 (he has had $0).
- Not included: the two unpaid gaps (nothing to refund), July to November (analytics were updating, with the gaps listed in section 1), and the two free months he asked for.

**How it runs: Aaron's authorization, not the machine path.** The 05-17 legal-action sentence is why. The two approval
records are staged in `data/legal-threat-refund-corredor-r1/approval-records/` and the wrapper refuses both, because
they say `legal_threat: true`. **Nothing here runs on its own, and nothing runs on the strength of the 11-15 answer:**
that answer was that the wall does not move, so a refund needs a fresh, case-specific authorization from him, quoted
with its date in a follow-up PR. Only then does a named person run the two refunds through the live gate with their own
Slack id and message timestamp (`--keep-subscription-confirmed-by`, `--override-confirmed-by` on the second,
`--approval-msg-id`), and the gate re-reads every fact below from Stripe and refuses on a mismatch. Then confirm with
`stripe charges retrieve <charge>` (`amount_refunded` 1250, `refunded` true) on each.

- Checked read-only against live Stripe at 2026-11-12 ~03:00Z: both charges are paid, undisputed, USD, $12.50, nothing refunded; the customer has 92 charges on one page (`has_more` false) and $0 refunded. The gate reads every page of a customer's charges before it compares with the cap, so a customer past 100 charges is totalled rather than refused.
- The 03-17 charge is eight months old; if the card has since been replaced the refund can fail, and the message must then state $12.50, not $25.00.
- **No refund runs until he authorizes this case.** The 2026-11-15 answer was that a refund paid after a legal threat is a settlement the caps do not authorize, so the earlier "run both tonight" instruction is withdrawn: it would have spent $25.00 irreversibly on an authorization that does not exist. The staged records are inert, unsigned, and refused by the wrapper while they say `legal_threat: true`.

**Revert.** A Stripe refund cannot be reversed, so there is no undo for either refund once it runs; the only correction is a new charge the customer agrees to. If only one should stand, run only the 05-01 one (`ch_3TSNiALsjTo3Ar3l1XZS146e`): its whole period was affected. What can be undone is the path itself: `touch /etc/hydra/refund-machine-approval.disabled` stops every machine-approved refund at once, removing `/etc/hydra/refund-machine-approvals/` disarms it, and reverting this branch's commit removes the flag.

### What the machine path is

`scripts/muso-stripe-write.sh --machine-approval <record.json>`, tests in `scripts/tests/muso-stripe-write-machine-approval.bats` (85 cases: the caps, the disputed and non-USD refusals, the customer-cap pagination, the used-check under one lock, the kill file, the second switch and its arming guard, the signature, and the four legal-threat refusals - true, true with a reference, missing, and a non-boolean - plus one case where `legal_threat: false` still runs and is audited; the existing 59 wrapper tests still pass).

- A record names the approver (`firstmate` is the only one on the table), the decision it comes from, the customer, the charge, the amount and its evidence. One record, one refund, used once.
- The gate checks the record against Stripe, not against itself: the charge is that customer's, paid, undisputed, USD; the amount is what the record approves; at most $150 for the refund and $300 for the customer counting everything Stripe shows refunded to them.
- It replaces the one-time override, and the keep-subscription waiver when the record says so. It never replaces the double-concession gate, and the model-health gate still runs first.
- The customer cap is compared with the refunds on every page of the customer's charges. The read ends only when Stripe says there are no more; a page that does not say so, a page that fails, a list that repeats or does not end within 50 pages (5,000 charges) is a refusal, never a smaller total.
- Above either cap, on a dispute, or with `legal_settlement`, `formal_claim` or `legal_threat` not false, it refuses and the human flags remain the only way. A legal-action threat is a named human's decision, so the machine path never runs one.
- `legal_threat` is required, so a record cannot leave the question out; only false passes. The gate cannot read the conversation, so this field, like the settlement and formal-claim fields, is what the record says and is not verified.
- An audit line is written before the Stripe call and another after. If the first cannot be written the refund does not run; a record whose earlier run left no outcome is refused, not retried.
- One lock is held from the used-check through the Stripe call and its outcome line, so two runs cannot both pass the caps against a pre-refund view of the customer; the second waits a bounded time and then refuses.
- A record is spent once, and rotating the log cannot unspend it: the used-check counts the audit lines that carry the record's sha (`grep -c`, so a 200KB line cannot make the pipeline read a used record as unused), a marker per record is written under `/var/lib/hydra/refund-machine-approvals/used/` in its own directory **before** the Stripe call and updated to `executed` or `failed` after it, and the Stripe call carries the idempotency key `machine-approval-<record sha256>` so a replay is deduplicated on Stripe's side even if both local files are deleted. There is therefore no interval in which money has moved and nothing durable says so: a crash leaves the marker at `intent`, and any marker blocks an automatic retry, so an ambiguous outcome is reconciled by a person reading the charge rather than by a second write. A marker directory that cannot be created or read refuses the write, and a caller-supplied `-i` is refused.
- Two switches, and the second is reviewable: the record directory alone cannot arm the class. `policies/refund-machine-approval-automation.json` must say `enabled: true` with a non-empty `approved_by` and `approval_ref`, and its caps must match the wrapper's compiled caps, so arming is a diff a reviewer reads rather than a `mkdir` on the host. **Both switches are re-read under the lock immediately before the money moves**, because a run can wait a minute on the lock and then read pages of charges: the kill file, the record directory and the record's sha were already re-checked there, and the row is now re-read too - a row flipped to `enabled: false`, or re-approved with different caps, in that window refuses the write instead of applying the authorization this process loaded at startup (regression cases 20 and 21). `scripts/check-refund-machine-approval-automation.py` fails CI when a change flips it without naming who approved the class and where (rules R1-R6 in its docstring), and on that flip both approval fields have to be new in the same change - a row disabled with an old `approval_ref` cannot be armed by setting only `approved_by`, which would inherit an approval nobody gave for this. PR Validation runs it against the base. The row is `false` today, which is why "nothing armed" does not depend on an operator remembering not to create a directory.
- Signing: a record is an approval only when the reviewer key signs those exact bytes. The wrapper verifies
`<record>.json.sig` against `policies/refund-approval-reviewer.allowed_signers` (`-I outbound-copy-reviewer`,
namespace `muso-refund-approval-v1`) and refuses an unsigned record, one edited after signing, one signed by another
key, and a copy-gate verdict replayed as an approval. That key is the copy gate's reviewer key: it lives on the
reviewer host and deliberately has no copy on node-8, so writing a record on node-8 cannot make it an approval.
Signing is `scripts/sign-refund-approval.sh <record.json>` on that host. Both Corredor records are staged
**unsigned**, which is the point - they say `legal_threat: true`, so neither the signer nor the wrapper would take them.
- Limits worth knowing: the evidence fields are required and recorded but not re-verified (a bash gate cannot re-run the analytics query), and nothing in the wrapper authenticates who wrote the record (it proves the decision was signed by the reviewer key, not that the evidence inside is true). Caroline (edge) has no route to it, but any agent with a root shell on node-8 (`operations`, `devops`, `cto`, `ceo`, `cmo`, `clio`, `qa` in `policies/agent-exec-policy.json`) can create the record directory, write a record and run the wrapper with no human on the path. The caps and the audit file are what bound it. The refund skill reserves a legal-action threat to Aaron and tells the Ops agent not to write a record for a refund it is running (prose, not enforcement).

## 3. Customer message

`customer-message.txt` is now the **acknowledgement only**, because that is what his 2026-11-15 answer calls for on a
legal-threat thread: it takes no position, names no figure and gives no date. It says his request is with a person, that
no answer or number comes on this message, that a decision will come to this conversation, and that anything he adds
goes with the request. It says nothing about the legal sentence, fault or liability, gives no reason for the delay, and
does not use fraud or bad-faith wording.

The earlier draft is withdrawn: it stated the refund and the $25.00 figure with a 5 to 10 business day window, and a
figure promised on a thread he has already put a legal sentence into is the settlement this policy exists to avoid. If
he decides to pay, the money message is a second, separate message that states the amount **after** the refund has
executed, quoting the transaction. "Your stream numbers are updating again" is held back for that message too, since it
only makes sense next to a fix.

Nothing has been sent. The send is `scripts/intercom-ops-write.sh reply --customer-facing --approved-by <a person>`, and
it needs an approved copy verdict for these exact bytes; the lane does not send through the gate on its own authority.

## 4. Is this an incident

- **In April and May: yes, platform-wide, not one customer.** The partition counts above are for every track, not his. Between 04-09 and 05-07 the store took 0.6% of a normal write once and nothing twice. I did not count how many paying customers complained or were refunded for it.
- **Today: no.** Of 38,719 paying profiles (`postgresql_core.public.vw_pro_profiles`), 21,487 have more than 100,000 lifetime streams; 52 of those show zero streams in the last 7 days and 40 in the last month (`cube_analytics_profile_view`, periods `1w` / `1m` / `all`). That is 0.24%, the size of the "genuinely inactive" class the house wiki already records.
- Separate surface, not checked further: 3,511 of 38,634 paying profiles have a credit-and-milestone stat cube (`cube_analytics_industry_stat_profile_view.last_computed_at`) more than 2 days old, the oldest from 2026-08-18.

## 5. Legal sentence

Not answered, not characterised, not referred to in the draft. Nothing in the thread or the tickets shows a letter, a claim number or a solicitor.
He has not repeated it since 05-17. The 11-12 ClickUp note records an escalation already sent to Aaron (Slack DM `1794444897.520449`), so this lane did not send another.

This refund is on Aaron's side of the line: the customer wrote a legal-action sentence on 05-17, and the refund skill reserves that class to him. It is not a settlement - nothing is asked of him in return and the message does not mention the sentence - but the class is his to authorize, so the machine path refuses it and both approval records sit staged, inert, awaiting a fresh case-specific authorization - his 2026-11-15 answer was that the wall does not move, so the earlier request for a yes/no is closed and a new one would have to be about this case specifically. If he repeats the sentence, or a letter, a claim number or a solicitor appears, that goes to Aaron in one line.
