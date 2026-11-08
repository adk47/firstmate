# Churn win-back: fix first, then one message (wb_fix_1)

325 paying users churned in 60 days while we owed them an answer. $5,371 list MRR: 60 unanswered
or a promise we did not keep, 81 told to wait on an open request, 184 with credits pending and
silence. Audit: `data/support-churn-winback-fable-c1/report.md` (Fable, ruling R2).

**R2 is the whole design.** No message goes to a churned user until the thing they waited for is
DONE and visible in the system of record. A user whose fix cannot be proven is not a message we
owe them today; they are a ticket in the lane that owns the fix. A message without a fix would be
the third time we told these people something that was not true.

Nothing in this build approves a credit, merges a profile, or issues a refund. It routes work to
the lanes that own it, reads back what they did, and only then renders the one email.

## The three stages

| Stage | Script | Cadence | What it may do | What it must never do |
|---|---|---|---|---|
| 1. Route | `scripts/route_fix.py` | daily | Put one fix ticket per (user, cause class) where the OWNING lane already looks, tagged `churned:<date>` with paid priority | Send anything, or invent a lane |
| 2. Read back | `scripts/fix_readback.py` | hourly | Mark a ticket Seen when the system of record proves the fix, and record the evidence | Trust a lane's own claim, or treat an unreadable source as "not fixed" |
| 3. Send | `scripts/winback_fix_send.py` | daily, dry-run default | Render, guard, ledger and hand ONE batch manifest to the sender seat | Send from the lane, or message anyone whose fix is not Seen |

Lane routing (R4 paid-priority) — every destination has a READER in this repo, which is the whole
test a routing decision has to pass:

| Lane | Owner that actually reads it | What stage 1 writes |
|---|---|---|
| credits, proof | the decider cron — `scripts/credit_review/decide.py` `order_rows()` via `load_churn_priority()` | an entry in `intake/churn-priority.json` (a 30-day flag anchored on the ROUTING run, so a user who cancelled 45 days ago is still promoted for 30 days from the moment we routed them) |
| claim, merge, analytics, refund, other / promise-not-kept | a person — the ClickUp User Requests board `901000600160` (`hydra-action-request`, drained by `resolve-notify.py`, `clickup-todo-dedupe.py` and the support agents) | one task, deduped by marker, tagged `churned:<date>` + `action:*` |

The credit and proof lanes deliberately write **no ticket and no queue of their own**: those
users' open requests are already in the decider's queue, and what they lack is the ordering — a
churned user is by definition no longer "paying", so `paid_tier` drops them into the free segment
at the exact moment we owe them most. `load_churn_priority` therefore promotes them to tier 0 for
`windows.paid_priority_days`; the entry lapses on its own, an unreadable file changes no ordering,
and the file approves nothing.

A refund over $150 still escalates to `cs-systemic-c3` (a human channel), not a G8 judge row. A
real (`apply`) run with no ClickUp credentials **refuses** those lanes (`lanes.LaneUnavailable`)
and exits 2 with the ticket left unrouted: a placeholder reference would persist as "already
routed", could never be read back, and that user would never be fixed and never messaged.

Ticket identity is `sha256(user_id \0 primary_class)[:24]`, so a re-run finds its own row and a
second run writes nothing. `--dry-run` creates no state at all (it uses an in-memory ledger when
none exists) so a rehearsal cannot become the record.

## What counts as Seen (stage 2)

Every reader fails **closed**, and "unreadable" is a third state, never a synonym for "not fixed":

| Lane | Seen means |
|---|---|
| credits / proof | the candidate must carry `credit_open.request_ids`; a ticket that names no request is held, because no decision can be attributed to the thing the user complained about. The decision and the status note must be about THOSE requests (a decision or note for a different request says nothing about the one the user complained about); EVERY named request needs a terminal outcome (`approved` or `unverified`/`user_verification_needed`), so one approved request cannot settle a ticket that also names a request still pending; at least one of those requests' latest outcome must be `approved` (a ticket whose requests are all declined is not a fix), AND every one of those requests has its own `status='sent'` `verify_messages` row **after that request's own outcome** (a note sent after a later approval does not stand in for the note an earlier-approved request needed). Both are dated against the user's OWN start of wait (their request, or an earlier open credit wait), raised to the churn-window start recorded on the ticket when it was routed — never against the routing run, so a fix that landed between the measurement and the routing still counts, and an approval older than the wait they complained about does not |
| claim | the claim this ticket is waiting on (its `claims.claim_id`, or the candidate's `profile_id`) is `processed` in Trino and that terminal row is not older than the user's wait. The NEWEST row for the user decides, so an old `processed` claim cannot certify a newer pending one. A ticket with no start of wait is `undatable`, and a processed row with no date is a `datagap`: neither can be dated, so neither is Seen |
| merge / analytics | ClickUp status type `closed`/`done` AND the `customer-outcome:complete` tag; analytics additionally needs an `as_of` in the past and inside 7 days (a future stamp is not a measurement) **and exactly one** platform named in the task (two is ambiguous, so it holds rather than putting a platform in a customer's copy that the fix never touched) |
| refund | the refund task a person closed, carrying `customer-outcome:complete`, a Stripe refund id (`re_…`) and `stripe_refund_amount` in DOLLARS (`49.00`, or grouped as `1,234.00`), AND the Stripe object itself (`${STRIPE_BIN:-stripe} get /v1/refunds/<id> -d expand[]=charge`) existing with `status='succeeded'` for exactly that amount AND belonging to the ticket's own `customer_id`. A refund for another customer, or one whose ownership cannot be read, is not Seen. The task's figure is a cross-check, not the source of truth; the message states Stripe's amount. A wrong/failed refund, a missing object and an amount mismatch are not Seen, and an unreadable Stripe CLI is UNKNOWN (stays routed, never `ineligible`). An amount that is not a number (`1,23.00`) also holds the ticket as unrouted-and-re-read, so a typo cannot close a refunded user out for good |
| other | an admin Intercom reply of `guards.human_reply_min_words` (40) words or more that is the **latest** part on a closed thread (a customer message after it means the issue was still live, and a recorded close time must not predate it) and is not a sweep line, and the ONE sentence the message quotes must clear its own, lower floor (`guards.human_reply_sentence_min_words`, 8) and name the fix — a reply that only greets and apologises has no sentence to quote, so it is held as a fixable policy gap rather than closed out. The reply must also be newer than the user's start of wait, and EVERY conversation on the ticket with activity at or after that wait must pass: an older closed thread with a long answer cannot certify a newer complaint that is still open, and a conversation that could not be read holds the ticket rather than being skipped |

A `hold` or `defer` decision is not a fix. An approval nobody told the user about is not a fix
either: the point of this campaign is the silence, so "approved and not yet communicated" stays
held until the verify note is actually `sent`.

Stage 2 (`scripts/fix_readback.py`) writes Seen or nothing: a ticket it cannot prove stays
`routed`. The terminal `ineligible` state is written by the SEND stage when it can render no
honest message for a ticket that is already Seen.

**Re-reading is a budget, not an endless hourly sweep.** The wait before attempt N is
`readback.backoff_hours[N]` hours after the previous attempt (`routed_at` for the first), so with
the shipped `[1, 6, 24, 72, 168]` a stuck ticket is read at about +1h, +6h, +24h, +72h and +7d —
five attempts over eight days. Each run takes at most `readback.max_per_run` (500) tickets,
oldest-due first, and holds `readback.lock` next to the ledger (O_EXCL, 0600, released in a
`finally`; a second run logs `another read-back is running (lock held by pid <pid> since <ts>)`
and exits 0). The lock carries the holder's identity — pid, that pid's `/proc` start time, the
boot id and the timestamp — and is taken over only when that identity proves the owner gone
(different boot, dead pid, a recycled pid whose start time moved, or a file older than the longest
plausible run). The takeover renames the stale file aside, so exactly one contender can win and
no run ever unlinks a lock another just created. A non-Seen read only writes a `fix_events` row when the VERDICT changes —
the same reason read twice updates the attempt counter, not the audit table. After the last
interval the ticket stays `routed` (never auto-`ineligible`) and the run emits exactly one line,
`need firstmate: task readback_exhausted <n> tickets`, so the owning lane drains it.

Non-eligible reasons carry a prefix the run depends on:

- `unreadable` / `reader error` — a **source** is down (Trino non-zero exit or timeout, a ClickUp
  or Intercom error, a missing Stripe credential, a thread whose every conversation read failed,
  or the credit ledger's `decision_outcomes` table unreadable or missing its columns).
  It does not spend an attempt — an outage says nothing about this user — and a run where every
  verdict is one of these exits `3`.
- `datagap` — the source answered and this **ticket's own data** is permanently incomplete: no
  `claiming` row, a ClickUp task somebody deleted, a refund task that records no Stripe refund id
  or no amount, a refund id Stripe does not hold, a conversation whose open/closed state is
  missing. It
  spends an attempt, lands in its own report bucket, and so exhausts and escalates instead of
  sitting at the head of every run for ever.
- `undatable` — the source answered and the candidate itself carries no start of wait (needs
  `request_at` or `credit_open.oldest`), so no fix can be dated. Also spends an attempt.

Anything else is "nothing yet". Only `unreadable`/`reader error` is ever reported as an outage.

## The message (stage 3)

Six fixed FIX_LINE variants, one per cause class, numbers from the read-back; `other` quotes the
human reply that was already sent in Intercom and is the only free text. Offers stay inside the
approved set (R3): `WB_M2_MONTH1` ($1 first month, redeem by the date in the policy),
`WB_M2_ANNUAL40` ($72 first year), a `payment_failed` churner gets a restart link and NO coupon,
and a Regional Discount user keeps their country coupon plus the regional sentence. Codes, slugs
and `redeem_by` are the live values in muso-messaging `contracts/email/coupons.json` — the
send-gateway refuses a body whose slug is missing there, so a stale copy here is a refused send
and not a silent discount.

The regional sentence states a price, so it has its own GO
(`offers.regional_suffix.fable_go_ref` = `fable-ruling-1104-d2/wbfix1-regional-suffix`) and a
per-user condition the snapshot cannot answer: the country coupon must still be live **at send
time**. A GO ref is only a claim: the approval itself is recorded in
`docs/support/copy-gos/wb_fix_1-regional-suffix.md` (the ref, the approved sentence verbatim, the
ruling verbatim, its date, the granting seat and its conditions, plus where the original archive
lives), which `offers.regional_suffix.fable_go_evidence` names. **No GO ref without an evidence
file**: `tests/test_churn_copy_gos.py` fails the build when a set `fable_go_ref` has no file, when
the file does not quote the ruling, or when it quotes a different sentence than the one the policy
would send. `scripts/churn/coupons.py` reads
the customer (and, when the customer carries no discount, the subscription) through the Stripe
CLI, one bounded read per customer cached for the run. `HELD` appends the sentence; `LAPSED` and
`UNVERIFIED` drop it and the message still sends — a Stripe outage must never block a message and
must never produce a false price statement. A rehearsal never calls Stripe: it treats every
regional user as `UNVERIFIED`, so `--dry-run` stays offline and deterministic. The send report
carries `sent_with_suffix`, `sent_without_suffix`, `held_coupon_lapsed` and `coupon_unverified`;
the first live day's sent-with-suffix / coupon-lapsed counts are posted to the Fable seat
(`verify-sla-driver-fable-d2`).

Every offer sentence carries the URL it tells the reader to use (`offers.offer_url` +
`offer=<slug>`), and the guard refuses a body that says "this link" with no muso.ai link in it: an
approved sentence promising a link we did not supply is the same silence this campaign exists to
fix. The template must spell the offer parameter percent-encoded (`%26offer%3D{slug}`): the
`payment_failed` link is built by dropping exactly that fragment, so `render.offer_url_for` raises
a policy gap when the spelling drifts rather than shipping a link with an empty offer parameter.

Two renderers, one copy source: `scripts/churn/render.py` renders a body per user, and
`scripts/winback_fix_template.py` emits the muso-messaging `wb_fix_1` drop-in from the same
policy. `tests/test_churn_template.py` renders every variant through both and requires the bodies
to be byte-identical, so the copy Fable reviewed is the copy a customer receives.

A body that cannot be filled honestly (zero approved credits, an ambiguous merge outcome, a
missing platform, no human reply) is not sent, and which kind of refusal it is decides whether the
ticket survives. The guard is a refusal gate, not a rewriter: forbidden vendor names (never
Klaviyo, never Jaxsta), the promise family that burned these users in the first place, internal
vocabulary, non-muso links, unfilled placeholders and a 40–220 word band all block the send rather
than editing it.

The two refusals are deliberately different, because the same verb would be a lie in one of them.
A **policy gap** (a missing coupon slug, link, amount, a sentence with no GO recorded — e.g. the
regional price sentence if its `fable_go_ref` is ever unset — or a human reply whose sentences
none of them names the fix) is fixable by editing the policy or re-wording the answer, so the
ticket keeps its evidence and stays sendable, and the reason is written to its event log. A **per-user dead end** (no approved credit, no answer to quote) cannot be repaired by
any future edit, so that ticket is closed as `ineligible` with the reason. Nothing in either class
is sent, and a policy gap that leaves the batch with nothing to send exits `2` rather than
reporting a quiet night.

Audience is highest list-MRR first, one decision per user (their highest-priority ticket, since a
user can hold one ticket per cause class), minus everyone we must not mail: back on a subscription,
staff/test, fraud watchlist, open dispute, major-label/publisher affiliation (a named human
answers instead), an unreadable core row, a core row whose live-subscription count cannot be parsed (unreadable, never read as zero), a `campaign_once` user, and
`sha256('muso-holdout:' + user_id) % 10 == 0` (`model.holdout()`), which is the holdout. That
prefixed hash is this campaign's own assignment: changing it would reshuffle the control group
mid-campaign, so it is part of the contract, not an implementation detail. The gateway still owns
suppression, unsubscribe, marketing-in-7-days and one-message-per-user-per-day; the lane records
that it delegated them.

## Gates

Three switches, all required for a live hand-off, and each one alone is not enough:

1. `template.enabled: true` **and** a `fable_go_ref` in `policies/winback-fix.json` — the Fable GO
   on the six rendered variants, backed by its own evidence file under
   `docs/support/copy-gos/`. The regional price sentence asserts a price, so it carries its own
   `offers.regional_suffix.fable_go_ref` and a Regional Discount user is held (never sent an
   unapproved price) until that one is recorded too.
2. `--live` on the command.
3. `/etc/hydra/winback-fix.live` present (override with `--live-flag`). The flag lives in `/etc`,
   not in the deploy's rsync target, so a deploy cannot arm the campaign.

The one-message-ever rule is a `UNIQUE(campaign, user_id)` constraint on `send_messages`, not a
code path. The batch's ledger rows and its hand-off manifest are written inside ONE transaction
(and only on a live run), so a dry run never consumes the message a user is owed and a manifest
that cannot be written rolls its claims back with it. The manifest is staged under a `.tmp` name
and only renamed to the name the sender seat reads once the claims are committed, so a commit that
fails leaves no manifest behind; a rename that fails after the commit releases the claims it had
written. Either way a batch that never reached the sender seat consumes nobody's one message
(`exit 4`).

A body that a guard refuses refuses the **batch**, not the user: the fault is in the copy or the
policy, so nothing is sent, no ticket is marked `ineligible`, and a corrected policy can send
tomorrow (`exit 2`). The one exception is the sentence quoted from a human reply (`other`): the
body carries that answer verbatim, so a violation whose trigger lives inside the quote is closed
on that one ticket ("the human answer we would quote names something we cannot send") and the rest
of the batch continues. The guard is run three times on such a body — the whole body, the
campaign-owned skeleton without the quote, and the quote alone — so the blame lands where the
fault is and one support agent's wording can never stall the campaign.

## Files on node-8

Everything lives under `/var/lib/hydra/churn/` — never `/opt/hydra`, which the deploy rsync
overwrites:

- `tickets.sqlite` (0600, in a 0700 state dir) — `fix_tickets` (one row per user+class, with
  `fixed_at` and `readback_json`), `fix_events` (append-only audit) and `send_messages` (the
  per-message ledger). Both tables store the staff reply verbatim on the `other` lane, so the
  ledger is protected exactly like the run artifacts: every read-write open makes the state dir
  0700 and the database (plus any sqlite journal siblings) 0600.
- `readback.lock` (0600) — held by the read-back run that is currently reading this ledger, so
  two hourly runs never overlap. Removed in a `finally`; the holder's identity and the exact
  takeover rule are described under "Re-reading is a budget" above.
- `reports/<stage>-<day>.json` (0600) — what each run did. The send report is `send-live` or
  `send-rehearsal`, never the same file: "what did we actually send" is answered after the fact.
  It is 0600 because the read-back report carries staff-authored text verbatim (`other`'s
  `human_reply`), not just counts: the file is created with `os.open(..., 0o600)` in a 0700
  directory, so it is never briefly world-readable, and nothing reads it back.
- **stdout is safe to capture; the artifact is the only place the staff text lives.** The
  read-back prints its document to stdout every run (the channel the hourly cadence captures),
  so that copy is the redacted view: every field listed in `readback.STAFF_TEXT_KEYS` is replaced
  by `<redacted, N words>`. The full text stays in `tickets.sqlite` and the 0600 report. A lane
  that records human prose adds its field to that one list (`scripts/churn/readback.py`), which is
  what `scripts/fix_readback.py` redacts with — no lane can leak by omission.
- `returns/<day>.json` (0600) — the +30 day measurement (`scripts/churn_returns.py` writes it
  under the state dir, not under `reports/`).
- `intake/churn-priority.json` (0600) — the churn priority list the credit decider reads
  (`churn-priority/v1`; `entries[]` of `{user_id, until, tier, cause_class, ticket_id}`). It is
  the ONE file stage 1 writes, and it is a sort key, not a queue.
- `outbound/wb_fix_1-<stamp>-<nonce>.json` (0600) — the batch manifest handed to the sender seat. The nonce keeps two batches that start in the same second from overwriting each other.

## Operating it

```bash
# 1. route today's audience (writes nothing to a send path)
./scripts/route_fix.py --no-clickup --dry-run      # rehearse: counts per lane, no state
./scripts/route_fix.py                             # route for real

# 2. read back what the lanes did
./scripts/fix_readback.py --verbose

# 3. rehearse the message; never consumes a ledger row
./scripts/winback_fix_send.py --show 2

# 4. the six variants for Fable GO (goes in the PR body)
./scripts/winback_fix_send.py --render-proof 6

# 5. returns vs the holdout (writes <state>/returns/<day>.json)
#    Each user is measured inside their OWN window - [that user's anchor, +30 days), anchored on
#    the moment the campaign touched them: their fix if the read-back proved one, otherwise their
#    routing. Anchoring only fixed users gave every unfixed control a window that could never
#    open, which diluted the holdout toward zero. The headline is intent-to-treat (every non-holdout
#    routed user) against the hash-assigned holdout. There is deliberately NO per-protocol
#    "messaged-only" number: the sender seat can reject a hand-off after this lane releases it and
#    its outcome never reaches this ledger, so such an arm would count claims as messages.
#    fixed-vs-unfixed is a SECONDARY split inside each arm, never the headline. Every denominator
#    (including an explicit `unmeasurable` count for users with neither anchor) is printed in the
#    artifact and on the one-line text.
./scripts/churn_returns.py --dry-run    # cohort sizes only, no Trino read
./scripts/churn_returns.py

# and the muso-messaging drop-in for the template PR
./scripts/winback_fix_template.py --out "$PAPERCLIP_RUN_SCRATCH_DIR/wb_fix_1"
```

`route_fix.py` and `fix_readback.py` are safe to schedule before the campaign is armed: they
touch only the lanes and this lane's ledger. Schedule them the way the repo schedules every other
deterministic job (`scripts/install-aux-units.sh`), and arm `winback_fix_send.py` only after the
three gates above are true.

Exit codes: `0` fine (including a read-back that found `readback.lock` held), `1` no ledger /
nothing to do yet, `2` refused (a switch is off, a guard blocked the batch, or a policy gap left
nothing to send), `3` a source was unreadable so nothing could be proven
(`readback.SourceUnreadable`: a Trino non-zero exit, a missing wrapper, or the 180s read timeout;
likewise an unreadable Intercom/ClickUp source), `4` the hand-off manifest could not be written or
published (its ledger claims rolled back with it, or were released). `3` is not an error to retry blindly — it means a lane's
system of record is down and every user it owns is held. A ticket with no start of wait is NOT
`3`: nothing is down, the ticket is short of data, and that is its own report bucket.

## What this build does not do

- It does not approve a credit, merge a profile, or refund a card. `policies/credit-approval-automation.json`
  lists every automation that may approve, and this is not one of them.
- It does not write to muso-messaging. `scripts/winback_fix_template.py --out <dir>` produces the
  `native.json` entry and the two body files; landing them in that repo is its own reviewed PR,
  and the template ships `enabled: false`.
- It does not schedule itself. Arming the cadence is part of activation, not of this change.

## Definitions used in review

- **Seen** — the fix is provable from the system of record, per the table above.
- **Held** — a real user with a real request that we have not fixed yet. Held is a work item, not
  a failure.
- **Unreadable** — we could not tell. Never silently treated as fixed or as unfixed.
- **Eligible window** — 7 days from `fixed_at`; after that the fix is old news and the message
  would be a surprise.
