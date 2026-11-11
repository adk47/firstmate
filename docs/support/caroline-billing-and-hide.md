# Billing and hide / remove: what Caroline does, what stays with a person, and every undo

Captain, 2026-11-11: billing requests and removing / hiding profiles should be handled by Caroline, not Jan,
without hurting Muso or the safety of the system.

The boundary this document holds:

- **A hide is reversible**, so rules prepare it and it has an undo.
- **A delete is not**, so it stays with a person. Nothing here deletes.
- **A refund spends money and cannot be undone**, so it is rule-driven only under a stated cap, with a veto window,
  and a person above the cap.

Machine copy: `policies/caroline-billing-and-hide.json`, pinned by `tests/test_caroline_billing_and_hide.py`
(every tool named is registered and not denied on edge; no ACTION moves money; every ACTION states its undo; Caroline
holds no refund, delete or hide write). The hide machinery is `scripts/gdpr_pipeline/` (`docs/support/gdpr-pipeline.md`).

## 1. Billing shapes

Measured 2026-11-11T19:25Z from ClickUp list `901000600160`: tickets not closed and not `resolved`, per queue tag.
The shape of each ticket is a first-match keyword read of its title and summary. It is a count, not a judgement.

**ANSWER** = Caroline answers from a read. **ACTION** = Caroline performs one bounded write. **FENCE** = she hands
off; the last two columns are what the fence costs today (unresolved tickets a person has to work).

| shape (`key`) | mode | the read | the write | billing-issue | subscription-refund |
|---|---|---|---|---|---|
| `why_was_i_charged` | ANSWER | `billing_status` | none | 9 | 0 |
| `plan_and_renewal_question` | ANSWER | `subscription_status`, `billing_status` | none | 0 | 0 |
| `invoice_or_receipt` | FENCE | `billing_status` | none | 8 | 1 |
| `failed_payment_or_card_update` | FENCE | `billing_status` | none | 7 | 9 |
| `plan_change_or_seats` | FENCE | `subscription_status` | none | 13 | 5 |
| `cancel` | ACTION | `billing_status`, `retention_offer_check` | `cancel_subscription` | 18 | 17 |
| `win_back` | ACTION | `retention_offer_check` | `retention_offer_apply` | 0 | 0 |
| `refund_request` | FENCE | `billing_status` | none | 38 | 51 |
| `charge_dispute` | FENCE | `billing_status` | none | 12 | 2 |
| `credit_balance_dispute` | FENCE | none (the balance is not in any read she has) | none | 0 | 0 |
| `chargeback_or_fraud` | FENCE | none | none | 0 | 1 |
| `other_billing` | FENCE | `subscription_status` | none | 6 | 0 |
| **unresolved** | | | | **111** | **86** |

New in the last 7 days: 18 billing-issue, 6 subscription-refund. Median age of an unresolved ticket: 33 days and
42 days.

Reading the table:

- **No new write was given to Caroline here.** Both ACTIONs already exist in `plugins/support-tools`, are anchored to
  the conversation's verified Intercom contact, are rate-limited (3 per 60 minutes) and move no money. The standing
  rule that no subscription-touching change reaches production without the captain's OK is why this is a statement of
  the boundary plus a test, not a new tool.
- **27 unresolved tickets are shapes Caroline already answers or acts on** (`why_was_i_charged` 9, `cancel` 18 in the
  billing queue) and 17 more cancel asks sit in the refund queue. They are in a human queue because the ask arrived
  mixed with a refund ask or before the tools existed, not because a person is needed.
- **The refund queue is mostly not refund work.** The 2026-11-01 read-only shadow of the refund judge found that 54
  of 174 open billing / refund tickets were already refunded in Stripe and only needed a reply and a close, and 15
  were not refund asks at all.
- **What the fences cost a person**: 89 refund asks (38 + 51), 14 charge disputes, 18 plan / seat / discount asks,
  16 failed-payment or card asks, 9 invoice asks, 6 one-off corrections, 1 chargeback. `credit_balance_dispute` is
  fenced and unmeasured: no ticket in the read named it.

### The refund rule

Caroline never issues, sizes or promises a refund. She reads `billing_status`, says what the read shows, and files
the hand-off (`subscription-refund`).

The rule that decides a refund is the captain's own (2026-10-30, confirmed as ruling 186):

| | |
|---|---|
| cap per refund | **$150** |
| cap per customer per year | **$300** |
| veto | 4 hours before the refund is sent; the captain can stop any of them |
| who it covers | the verified Intercom contact, for a USD charge that code found in Stripe (never the amount the customer states), not already refunded, in a class the judge's coded gates name |
| above the cap | the captain decides. The judge writes the facts and stops. Nothing is refunded, and the customer is told only that the request is being looked at |
| never by rule | fraud or a stolen card (deny); an open chargeback; a non-USD charge; a request whose text carries instructions or states an amount above the cap |
| after a refund | paid access ends first, and no cash refund sits on top of a live credit balance (`scripts/muso-stripe-write.sh` refuses otherwise) |
| undo | none. A Stripe refund cannot be reversed |

**This rule is not live.** The judge is shadow-only in https://github.com/Muso-AI/hydra/pull/1624 (unmerged), and
running it live needs a write-scoped Stripe key that only the captain can mint. Until both, every refund is decided by
a named person in #operations, and the cost is the 89 refund asks above plus about 6 new a week.

It is also narrow by measurement: over the 174 tickets of the 2026-11-01 shadow the rule would have approved **one**
refund ($107.50). Most refund asks do not match a coded class on Stripe's facts. So the cap removes little of the
queue; replying to and closing the already-refunded tickets removes more.

## 2. Hide and remove

Caroline holds no hide write and no delete. A hide or removal ask becomes a row in the erasure register
(`scripts/gdpr-pipeline.py`); code decides identity, code prepares the reversible hide as two PRs, a person merges,
and only a public read-back (410 + noindex) marks the row hidden.

### What was actually blocking hides (measured 2026-11-11T19:28Z, register on node-8)

The planning number was "320 erasure requests past the hide deadline with nothing hidden". Measured the same way it
is now **355** of 464 open rows. That number is not 355 hides waiting on a pull request:

| of the 355 | rows | what the row is waiting for |
|---|---|---|
| nothing can be hidden yet: the request named no page (`ASK_LINK`) | 154 | the customer's answer. 51 of these are legal-threat rows that have been sent **no** ask, because the ask copy is approved for privacy-erasure requests only |
| the page is already gone (`GONE`) | 66 | a written confirmation, not a hide |
| a read did not complete (`UNKNOWN`) | 37 | the next tick |
| a person's call (`JAN_REVIEW` 34, `JAN_BIGNAME` 3, `DMCA_REVIEW` 2) | 39 | Jan |
| Art. 15 access requests and non-erasure rows | 29 | no hide is owed |
| identity not established (`ASK_IDENTITY`) | 14 | the customer |
| on one hide list only (`HIDDEN_PENDING`) | 1 | the other PR |
| **owes a hide now, routine** (identity PASS) | **4 rows, 8 pages** | a person merging the batch PR |
| **owes a hide now, legal threat** (`LEGAL_HIDE_FIRST`) | **11 rows, 18 pages** | one command, see "Legal threats" |

Two things in the brief for this work were stale when measured: H-DevOps #5012 and platform-data-processing #2581
were merged on 2026-11-09, and register #266 is a big-name profile (popularity 68, 774 credits) held by the big-name
rule, not a track.

**The honest number to drive to zero is "rows that owe a hide now": 15 (4 routine + 11 legal).** `tick --page`
already pages on exactly that set. The raw 355 cannot reach zero by hiding, because for 340 of those rows there is
nothing eligible to hide.

### Change 1: a track or an album passes through the same identity gate

Before, every non-profile page was `JAN_REVIEW` ("identity paths A-D are about profiles"). 28 overdue rows carry a
track or an album.

Now (`identity.decide_item`, `sources.item_page`): the item's artists are read **from the catalog**, and the item
passes only when it has **exactly one artist** and that artist's profile passes `identity.decide_page` for this
requester and this class. It is the same function with the same evidence: a processed claim, an account name, a
verified sender's name, the page's own website domain, the verified-sender rule and the big-name exclusion.

It is not weaker than the profile gate, and in four places it is stricter:

- an item of popularity 60 or more goes to Jan on every path, including a claim;
- two artists means a person decides, because the hide would take down someone else's page too;
- an item can never produce an ask: the approved ask copy is written about a profile, so an item that does not pass
  stays `JAN_REVIEW` with the reason;
- anything not established (no such item, an untyped field, a deleted artist profile, a part id) stays with a person.
  A read that did not complete is `UNKNOWN` and the run exits 2, as for a profile.

Shadow run of this gate against a copy of the live register (read-only, 2026-11-11, 41 open rows, 240 item pages,
0 read errors):

| result | pages |
|---|---|
| `JAN_REVIEW` -> `PASS_A` (the requester's account holds the processed claim on the one artist) | 2 (#369 album, #334 track) |
| `JAN_REVIEW` -> `LEGAL_HIDE_FIRST` (legal threat, small item, small artist) | 5 tracks on 3 rows (#364, #78, #188) |
| `JAN_REVIEW` -> `JAN_BIGNAME` | 1 album on 2 rows (#252, #418) |
| unchanged | everything else |

Why most items stay with a person, by count: the catalog no longer has the track (66); a DMCA row with no account
to hold a claim (38); the one artist's profile was already deleted outside the process (36); no artist in the catalog
(14); only part of the id is on file (18); a legal threat whose artist cannot be read (14); two artists (4); the
artist needs an identity answer first (3). So the item gate opens the route. It does not empty the item pile, and the
36 "artist already deleted" pages are the visible cost of deletes made outside the register.

**One thing has to land in platform-data-processing first.** Its strict test only knows erasure *profiles*. Until
the test has a set for items, the pipeline prepares an item in **neither** repository and says so on every run
(`blocked (track/album <id>)`), rather than rewrite the assertion from here. The one-time change, in
`tests/unit/test_sitemap_legal_hidden.py`:

```python
# A track / album hidden for an erasure request (gdpr-pipeline): id -> its entity.
ERASURE_ITEMS: dict[str, str] = {}


def test_committed_list_holds_the_cd_and_erasure_profiles():
    legal_b = {i for i, (_e, ref) in LEGAL_HIDDEN_ENTITY_IDS.items() if ref.startswith("legal-B-")}
    assert set(LEGAL_HIDDEN_ENTITY_IDS) == CD_PROFILES | ERASURE_PROFILES | set(ERASURE_ITEMS) | legal_b
    ...


def test_erasure_entries_cite_their_register_number():
    for i in ERASURE_PROFILES:
        entity, ref = LEGAL_HIDDEN_ENTITY_IDS[i]
        assert entity == "profile" and ref.startswith("gdpr-erasure-register-")
    for i, kind in ERASURE_ITEMS.items():
        entity, ref = LEGAL_HIDDEN_ENTITY_IDS[i]
        assert kind in ("track", "album") and entity == kind and ref.startswith("gdpr-erasure-register-")
```

The list file itself needs nothing: it already holds 27 tracks and 1 album from the 2026-10-23 legal batch.

### Change 2: one live batch pair that always carries the whole set

The old rule was "one pair at a time: while a pipeline PR is unmerged, defer". Its reason is real: both PRs insert at
the same point of the same file, so two open PRs conflict. But deferral was per repository, and that put the two
repositories permanently out of step (measured 11-10 and 11-11): H-DevOps #5105 opened while its PDP half waited
behind PDP #2582, then PDP #2583 opened while its H-DevOps half waited behind #5105. An id whose two halves are never
open together is never hidden.

The reason is kept and the deferral is gone (`hide_batch.open_prs`):

- each repository has **one** pipeline PR, and it carries everything the register wants hidden that `main` lacks;
- a run whose open PR already adds exactly that set touches nothing, so a pending review stays valid;
- when the set changed, or the open PR conflicts with `main` and so cannot be merged, a **new** PR is opened from `main` with the whole set, and only then is the old one closed
  with a comment naming its replacement. Never a force-push, so an approval cannot ride onto ids its reviewer did not
  see, and never a branch delete;
- a routine run keeps the legal-threat ids that an `--include-legal` run already put in the open PR, and never adds
  one itself;
- if what an open pipeline PR adds cannot be read, that repository is left alone and the run exits 2.

The batch now runs four times a day (00:20, 06:20, 12:20, 18:20 UTC) instead of once. The hide is owed within
24 hours; one run a day could spend the whole window before a person saw the PR.

**Merging stays with a person.** The three pipeline PRs open at the time of writing
(https://github.com/Muso-AI/H-DevOps/pull/5105, https://github.com/Muso-AI/platform-data-processing/pull/2582,
https://github.com/Muso-AI/platform-data-processing/pull/2583) are replaced by one pair on the first run after this
ships.

### Legal threats

- A legal-threat request on a small page is `LEGAL_HIDE_FIRST`: the hide is owed on the same 24-hour deadline, with no
  identity step first (captain, 2026-10-23: hide the disputed item now, as narrowly as the claim allows, reversibly).
  It is the same reversible hide with the same undo. A big-name page goes to Jan.
- The hide is mechanical. The legal assessment and the reply to the threat are not: they stay with the captain or
  counsel, and the pipeline sends a legal-threat requester no ask (that copy is approved for privacy erasure only).
- Nobody is waiting on a legal view for the hide. What they are waiting on today is one command. The routine batch
  leaves these pages out, because a page the captain withdrew from an earlier batch (register #126 / #246) has no
  record in the register that would keep it out. The way in is:

  ```
  /opt/hydra/scripts/gdpr-pipeline.py hide-batch --include-legal             # prints the batch
  /opt/hydra/scripts/gdpr-pipeline.py hide-batch --include-legal --open-prs  # prepares the PRs
  ```

  11 rows (18 pages) are past their deadline on that command, the oldest due 2026-09-18. After it runs, later routine
  runs keep those ids in the PR.
- Legal-threat rows that named no page (51) get no ask, because that copy is approved for privacy erasure only.
  Releasing it for another class is a ruling on customer copy (`copy.ASK_APPROVED_CLASSES`), not a code change.

## 3. The delete boundary

Caroline, and every automation in this document, may **not**:

- delete a profile, a credit, an account or any record. `DELETE /api/v3/admin/profile` and `muso-cli` delete are
  reachable from neither Caroline nor the erasure pipeline (legal hold 1350; a test greps the package);
- issue, size or promise a refund;
- assert a legal position, say where data came from, or promise a date;
- close an erasure request that has hidden nothing and told the person nothing.

They **may** restrict (hide), verify, log, triage and draft. A hide carries its reason (the register number, in the
list file's own ref and in the PR table) and the undo below.

## 4. Undo

| automated action | undo | who can run it | what it restores |
|---|---|---|---|
| a hide of a profile, track or album | remove the id from `HIDDEN_ENTITY_IDS` (H-DevOps `k8s/prod/core-services/deployments.yaml` and `k8s/dev/dev-deployments.yaml`) and from `LEGAL_HIDDEN_ENTITY_IDS` plus the test set (platform-data-processing), one PR each | anyone who can merge to those two repositories | the public page (200, indexable) when the H-DevOps change rolls out, and its sitemap entry on the next sitemap run. Not restored: the entry's scrubbed `changed/` sitemap history, which ages out by itself. Nothing in the catalog was deleted |
| a hide batch PR that is not merged yet | close the PR | anyone with write access | nothing was changed |
| a pipeline PR closed as superseded | reopen it (`gh pr reopen <n> -R <repo>`); its branch is never deleted | anyone with write access | the earlier PR, as reviewed |
| `cancel_subscription` (ends at the period end) | before the access-until date: the customer resumes in Settings > Billing, or Operations clears cancel-at-period-end in Stripe | the customer; Operations staff | the renewal. After that date there is no undo: it is a new subscription |
| `retention_offer_apply` (the product's own save) | Operations removes the discount from the subscription in Stripe | Operations staff | the full price from the next invoice |
| a refund | none | nobody | nothing. This is why it has a cap, a veto window and a person above the cap |

Stopping everything: `/etc/hydra/gdpr-pipeline.disabled` stops every writing run of the erasure pipeline, including
the batch. `cancelSubscriptionEnabled` and `retentionOfferEnabled` in the edge plugin config turn each billing write
off.
