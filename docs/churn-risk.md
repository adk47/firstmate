# Churn-risk signal: who is paying us and waiting on us

Captain 2026-11-03 ~21:10Z (verbatim): *"i think we may be losing some users on
subscriptions because we are not handling support properly investigate get on it
and win them back"*.

Measured over 60 days (report §0, 1,995 paying churners, $32,904 list MRR):
**325 users (16.3%) left with an unhandled support state, $5,371 list MRR**
(T1 86 / T2 81 / T3 184). The unanswered-thread slice churns at 2-2.5x the paying
base rate; the pending-credit slice matches the base rate only because ~2,700
paying users sit in that state on any given day.

This page is the operator's view of the running system. The design rationale is
in `data/support-churn-winback-fable-c1/report.md` (Fable lead, 2026-11-03) in the
firstmate data dir, not in this repo.

## What runs

| when | what | file |
|---|---|---|
| 04:15Z daily | build the store: `--paying`, then `--churned-since 30d`, then publish `risk.json` | `scripts/churn/nightly.sh` |
| hourly at :20 | page ops on a cancel / cancel-request with an open issue | `scripts/churn/cancel_with_open_issue.sh` |
| Monday 08:00Z | the weekly line | `scripts/churn/weekly_line.sh` |

The Monday line reads the store, not Intercom. When the last churned sweep is
missing, stale, or finished with source errors the line still prints, but the
warning rides ON the posted line (and in `--json`'s `warning`, and on stderr for
the cron log): a partial sweep undercounts and must not read as this week's
measurement to the person reading it in Slack.

Wiring: `scripts/churn/install-cron.sh` is the ONE author of
`/etc/cron.d/hydra-churn-risk`, and `scripts/install-aux-units.sh` executes it (it
carries no heredoc of its own). That is what lets the suite run the real writer
against a temp root and assert the installed file instead of grepping installer
text. The installer EXPORTS the `HYDRA_ROOT` it was given, so the child writes
cron lines naming THAT tree: the variable used to be a plain assignment, which a
child process cannot see, so a staging install (`install-aux-units.sh
/srv/hydra-staging`) silently wrote `/opt/hydra/...` entries. The suite pins the
seam by driving the installer's own argv through `HYDRA_STOP_AFTER=churn-cron`
(it installs only that one cron file and exits, so no root and no unit writes).
Everything lives under the policy's `store.dir` (`/var/lib/hydra/churn/` in
production - never `/opt/hydra`, which the deploy rsync overwrites). Every wrapper
derives its paths from that one field, including the weekly line's stderr file, so
a canary policy on a host without the production directory still renders:

```
support-state.sqlite   the store, keyed (user_id, mode): a paying row and a churned
                       row coexist, so a re-subscriber keeps their cancel history
risk.json              what the readers consume, published by risk.py
intake.jsonl           the cancel alert's lane rows (tag churned:<date>)
cancel-alert.watermark, cancel-alert.sent.json, *.log
```

## The three readers, and why each fails the way it does

- **`sources.py` fails LOUD.** A Trino, ClickUp, ledger or proof read that breaks
  raises `SourceError`; it never returns an empty list. Empty would look exactly
  like "nobody is waiting", which is the one wrong answer this system exists to
  avoid.
- **`risk.py` fails CLOSED.** It writes nothing when either nightly sweep (paying
  or churned) has never finished (exit 3), is older than
  `thresholds.risk_max_age_hours` (exit 4), or finished with source errors (exit
  5). A fresh timestamp over stale or partial rows is the only way an ordering
  signal can quietly move the wrong user to the head of a send queue, and a
  failed Intercom search looks exactly like "nobody is waiting". A `CHURN_LIMIT`
  canary run never publishes at all: a file built from a slice of the paying set
  would say nobody else is waiting on us. Both a canary sweep and the `--user`
  path record their run under their own mode, so only a full sweep can satisfy
  these guards.
- **A canary or a `--limit` run is bounded on BOTH sweeps.** `--limit` caps the
  per-user work -- the replica lookups and Intercom GETs -- for `--paying` and
  `--churned-since` alike, and a limited sweep also leaves the paying rows it did
  not look at in place. The churned window query itself still reads the whole
  window, because which users cancelled in it is what the cap selects from.
- **`risk_reader.py` fails OPEN.** Missing, malformed, stale, future-dated or
  killed means *no override*: every queue keeps its own order, which is always
  safe. It validates the document's SHAPE before loading a row and requires a
  usable `generated_at`, so valid JSON with no timestamp (which would otherwise
  never go stale) is rejected rather than trusted. It never raises, and an
  unknown user is never risk. A consumer can therefore adopt it with one line and
  no new failure mode.
- **`risk.py` is never called after a failed sweep.** Its own age guard would let
  yesterday's successful run be republished with today's timestamp (24h is inside
  `risk_max_age_hours`), so `nightly.sh` skips publication outright when either
  sweep failed: a state today could not confirm must not be stamped fresh.

## The classes

`customer_last` (they spoke last and have waited), `promise_no_followup` (we
promised and did not), `request_pending` (credit/claim/proof open past 48h with
no status note), `proof_no_update` (they sent proof, nothing came back),
`told_to_wait` (open thread, we spoke last, no ask) and `pending_task` (ClickUp
intake still open; the stage kind behind `request_pending`, so that is what the
store row and `risk.json` call it).

`told_to_wait` is deliberately **not** a risk class: a user we told to wait is not
being dropped. It still counts in the store and in the weekly line.

Tiers: **T1** `no_reply`, `promise_not_kept`, `proof_sent_no_update` · **T2**
`open_told_wait` · **T3** `pending_request`, `pending_claim`, `pending_task`.

Cause classes route to lanes (`policy.lanes`): `credits_not_approved` and
`proof_sent_no_update` → credit-review, `merge_claim_stuck` → merge-queue,
`billing_confusion` → refund-judge, `analytics_stale_wrong` → analytics-followup,
everything else → caroline-backlog.

## Consumers (the one-line contract) - wired in a FOLLOW-UP PR

```bash
python3 /opt/hydra/scripts/churn/risk_reader.py order --file <built list.json>
```

Always exit 0. A reorder never invalidates a signed audience: the builders'
`replica_facts` header hashes a **sorted** list of `[user_id, facts]` pairs
(`need_asks.facts_header`, `owing_proof.facts_header`), so moving entries changes
no signature. It is a reorder and never a filter: the reader can only move someone
*earlier*.

**Nothing in this PR reorders a send queue.** Scope ruling 2026-11-04 17:16Z: even
a change gated on a missing file is a change to the credit-send path and gets its
own review, so `scripts/credit-verify-outbound.sh` and `scripts/credit_review/decide.py`
are untouched here, and `scripts/tests/install-aux-units-churn-risk.bats` pins that
(it fails if THIS branch changes either file - or the credit-send tests - relative
to the merge base with `origin/main`, so main moving ahead on its own cannot turn
it red). Firstmate ruled the split accepted (2026-11-04 17:35Z) and the
follow-up is open as a DRAFT PR,
https://github.com/Muso-AI/hydra/pull/1774 ("credit-send queues read the
churn-risk signal"), linked from #1771. It carries exactly two changes, both
recorded in `policies/churn-risk.json` `consumers` (`state: wired` there, and
`follow-up-pr` here so this branch's file describes what THIS branch ships):

- `credit-verify-outbound` - `churn_order()` on owing-uvn, receipts-received,
  need-asks, reply-due and the filtered claim list (`state: follow-up-pr`).
- `credit-review-held-rows` - `order_rows()` prepends `risk.sort_key()`, covering
  judge and apply (`state: follow-up-pr`).

d2 owns the outbound tick and Fable reviews the credit path; coordinate with
`verify-sla-driver-fable-d2` and `verify-program-lead-fable-l1` before touching tick
order. The three lanes outside this repo (claim list builder, merge-queue intake,
Caroline backlog drain) are `pending-lane`: each is the same one line, added by the
lane that owns it.

Until that follow-up lands, the signal is fully observable and has no effect on any
send: the store, `risk.json`, the hourly page and the weekly line all run on their
own.

## The cancel alert

Two watched moments, both from the core replica (no Stripe call, no new secret):

- **cancel** — `subscriptions.status = 'cancelled'` since the watermark.
- **request** — a live subscription with `details.autoRenew = 'false'`, which is
  the fact Stripe's `customer.subscription.updated`
  (`cancel_at_period_end = true`) already writes through the billing webhook. This
  buys up to ~23 days of runway before the period ends.

Either moment joins the user to an open issue - the store row first, then the
published `risk.json`, then an on-demand classification for a cancel the nightly
sweep has not seen yet (bounded by `alert.on_demand_max` per run) - and pages the
ops channel with `paying user cancelled with an open {class} issue ({age}d, ${mrr}):
route -> {lane}`, appending the row to `intake.jsonl` with tag `churned:<date>`.
Dedup is per user for `alert.dedup_days` (30). A `customer_service` /
`low_quality` survey on a flagged user pages immediately and sorts first. The
`${mrr}` is priced from the cancel event's own plan at list (then the live
subscription row, then the policy default): a canceller has no live subscription
row left, so the event is the only truthful price for the page and for the MRR
ordering behind it. **The alert never contacts the customer.**

`cancel_alert.py --commit` runs only after every Slack post is confirmed: a failed
post leaves the watermark and the sent ledger untouched, so the page retries next
hour instead of vanishing. A watermark older than 30 days (or a missing one) is a
cold start = `now - 6h`, so a fresh install never pages a month of history.

A commit that cannot be WRITTEN (full or unwritable state filesystem) is a failed
tick in both branches, and the wrapper exits non-zero for it. After a confirmed
post that means the next hour re-pages the same payer - a duplicate page is the
honest outcome, and a green cron log over an unsaved watermark is not. In the
quiet-hour branch (no alerts) it means the same cancels are re-scanned next hour
rather than reported as a clean sweep.

The on-demand path never walks the fleet. Asking Intercom about one contact returns
a TYPED outcome - `no-identity` (we hold no external_id/email), `not-found`, `none`
(the contact exists with zero conversations), `found` or `error` - and only `error`
falls back to a window walk, bounded (`FALLBACK_MAX_PAGES`, `FALLBACK_MAX_SECONDS`)
and logged in `intercom.errors`. `no-identity`, `not-found` and `none` are the
normal, cheap answer for the ~84% of churners with no open issue, and classifying
them must not cost ~90 fleet search pages against the same token the nightly sweep
uses. Intercom keys a contact by ONE identity, so the lookup asks EVERY identity
we hold - the auth0 subject, the profile id and the email - and merges the answers,
deduped by conversation id. Only `not-found` on all of them is conclusive, and a
`none` (contact exists, zero conversations) on one identity does not stop the
probe: a person can have two contacts, and the unanswered thread can hang off the
other one. Otherwise a contact the mobile app created under the profile id or the
email is read as "no open issue" and the watermark advances past a real
cancellation. Threads the nightly sweep could not tie to a contact (a duplicate contact
carrying the same auth0 id) come from the stored `conv_state` instead.

ClickUp is read **once per tick**, not once per canceller. The intake list is
~14,100 tasks / ~141 pages, and an hourly tick may classify up to
`alert.on_demand_max` cancellers, so the same snapshot is matched against every
canceller in that tick. It matters that it is read at all: ~134 of the measured
churned-with-issue users are carried ONLY by the ClickUp intake list, so the
on-demand path used to answer "no open issue" for exactly that class. A ClickUp
read that FAILS is not an answer either - it is `unclassified` with the reason,
the same as an Intercom read that failed, and `--no-clickup` says so on the row
(`row["clickup"] = "not-read"`) rather than pretending it looked.

A candidate whose join could not be decided (the on-demand classification raised,
or `alert.on_demand_max` was already spent) is **`unclassified`**, never "no open
issue": the commit stops the watermark at the oldest such cancel, the wrapper logs
it and exits non-zero, and the next hour reads that cancel again (its already-paged
neighbours are suppressed by the sent ledger). Without that, a replica or Intercom
blip would advance the watermark past a real page and the user would be invisible
for the whole 30-day dedup window.

## Kill switch

`/etc/hydra/churn-risk.disabled` stops the consumers' sort override, the hourly
alert and the weekly line. It deliberately does **not** stop `nightly.sh`: the
store keeps building, so turning the switch back off never loses history.

## Checking it by hand

```bash
python3 /opt/hydra/scripts/churn/support_state.py --user <id>            # one user, no enumeration
python3 /opt/hydra/scripts/churn/support_state.py --churned-since 60d --dry-run --json
python3 /opt/hydra/scripts/churn/risk_reader.py stats
python3 /opt/hydra/scripts/churn/risk_reader.py is-risk <id>; echo $?   # 0 = risk
python3 /opt/hydra/scripts/churn/risk_reader.py order --file <list.json>  # what a consumer will do
python3 /opt/hydra/scripts/churn/cancel_with_open_issue.sh              # CHURN_DRY_RUN=1 to render only
python3 /opt/hydra/scripts/churn/weekly_line.py --json
```

`support_state.py --churned-since 60d --no-clickup` reproduces report §0: measured
on node-8 2026-11-04 (1,942 still-churned users, 60-day window) it read **328 users
with an unhandled state / $5,375.50 list MRR** against the report's **325 / $5,371**
(+0.9% / +0.08%). If it stops doing so, the stage rules or the price table moved and
the weekly line is no longer comparable with the baseline it prints.

Two deltas are expected and neither is a bug:

- **The tier split shifts even when the total does not** (measured T1 104 / T2 67 /
  T3 157 vs the report's 86 / 81 / 184). The report anchored a voluntary cancel at
  Stripe's `canceled_at` (the *request* moment, median 23.3 d before the period
  ended); the replica carries no request timestamp, so this anchors at the cancel
  time. A thread we answered between the request and the end moves from T1 to
  nothing, one we went quiet on moves from T2 to T1. The union is the stable number.
- **The ClickUp intake is the biggest single slice.** The report's ClickUp read returned one
  page of 100 tasks and it recorded that as a known gap. With the intake list paged
  properly until empty the same window reads 382 users / $6,328 list MRR, because
  ~134 of those users had an open merge/analytics/claim ticket nobody had moved.
  Those are real dropped balls (R4 routes them), so the nightly keeps them and the
  325 baseline is a **floor**. Week-over-week comparability comes from the line's own
  previous-week figure, not from the report's number.

## Tests

- `scripts/tests/test_churn_risk.py` — stage rules and tier precedence, store
  round trip, risk classes and the fail-closed publisher, the reader's fail-open
  cases, the alert's join/dedup/commit, the weekly line's window math, and the
  Intercom row → thread shape (the 2026-11-04 canary crash).
- `scripts/tests/churn-cancel-alert-delivery.bats` — the cancel wrapper's
  commit-after-confirmed-post contract, executed against a stubbed `muso`: a
  failed post leaves the watermark and the sent ledger untouched, so the page
  retries next hour instead of being deduped away for `alert.dedup_days`, a
  commit that fails after a confirmed post (or in a quiet hour) exits non-zero
  instead of reporting a successful tick, and an unclassified candidate exits
  non-zero instead of reading as a quiet hour.
- `scripts/tests/churn-nightly-publish.bats` — the nightly wrapper, EXECUTED with
  stub sweeps: the healthy night sweeps and publishes, a failed paying sweep or a
  failed churned sweep never calls the publisher, a canary (`CHURN_LIMIT`) run
  never calls it, and a dry run only renders (`--dry-run`).
- `scripts/tests/install-aux-units-churn-risk.bats` — the cron wiring, EXECUTED:
  it runs `scripts/churn/install-cron.sh` into a temp root and asserts the parsed
  schedule entries, the file mode, the state dir mode, that every named script
  exists, that narrowing the run twice converges, that the command lines carry no
  env assignments, and that the INSTALLER's argv decides which tree the lines name.
  No installer source text is asserted.
- These suites clean up in `teardown()`, never with an `EXIT` trap armed inside
  `setup()`: in bats 1.14 that trap swallows the failure report of a FAILING case
  (it prints "Executed 0 instead of expected N tests") and the suite would go green
  by losing the test.
