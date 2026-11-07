# bulk-credit-change drainer

Operator reference for `scripts/clickup_drain/bulk_credit_change.py` — the drainer
for the `action:bulk-credit-change` ClickUp queue ("Update credits on multiple
tracks"). Test coverage: `tests/test_bulk_credit_change.py`.

**Status as shipped: SHADOW.** The cron
(`clickup-drain-bulk-credit-change`) runs the script *without* `--apply`, so it
reads the queue, validates, and prints counts — and writes nothing. Arming it is
a captain decision (see "Arming" below), not a code change.

## Why this queue got a drainer

"Update credits on multiple tracks" is the ticket a customer files after pasting
a list of tracks and the roles they say are wrong. It has the highest
minutes-per-ticket of the seven queues and the worst failure shape: a human opens
N tracks, edits N credits by hand, stops when the session ends, and the ticket
still says "to do" with *some* of the rows applied. 99 of them were open on
2026-11-03, with no drainer and no close path.

## The manifest is the ticket

The drainer reads **only** the ticket's top-level `customer_profile_id` and its
`details.bulk_rows`, both from the `---ACTION-REQUEST---` block:

```json
"customer_profile_id": "<customer-profile-uuid>",
"details": {
  "bulk_rows": [
    {"track_url": "https://credits.muso.ai/track/<track-uuid>",
     "profile_id": "<customer-profile-uuid>", "role": "Mixing",
     "intent": "add"},
    {"track_id": "<track-uuid>", "profile_id": "<customer-profile-uuid>",
     "role": "Mastering", "intent": "add", "remove": false}
  ]
}
```

Prose-only tickets are refused as **`unparseable`** and write no tag, so they
stay waiting-on-us and the run report's "manifest hit rate" says whether the
intake (`workspaces/support/skills/action-request`) or the executor is the
problem. That number is the point of shipping this in shadow first.

Row rules, all enforced before any write (`scripts/clickup_drain/manifest.py`):

| Rule | Refusal reason |
| --- | --- |
| the ticket carries a top-level `customer_profile_id` | `missing-profile-anchor` |
| `track_url` XOR `track_id`; URL must be a Muso track link | `row-invalid` |
| `profile_id` on every row, equal to the ticket's `customer_profile_id` | `row-invalid` / batch refusal |
| `role` is the role the profile should HOLD (desired end state) | — |
| `intent` present and equal to `"add"` | `row-invalid` (missing/unknown) |
| `intent` of `replace`/`change`/`swap`/`remove` | `removal-refused` |
| ≤ 25 rows, no duplicate (track, profile, role) rows | `too-many-rows` / `row-invalid` |
| unknown row key (e.g. `removal: true`) | `row-invalid` |
| `remove: true` **or** `from_role` | `removal-refused` |

`intent` is required because a row that names only a role cannot distinguish
"also credit me as Mastering" from "change my Mixing to Mastering". Both arrive
as `role: "Mastering"`, and the second is a removal plus an add: the drainer
would add Mastering, read it back, and report `complete` while Mixing still
displays — the customer's actual request half-done and the ticket closed. Only
`add` is executable. A `replace`/`change` row is refused as a removal (tagged
`blocked`, routed to the human path); a missing `intent` is `row-invalid` and
tags nothing, because that is an intake defect rather than a request we decline.

Why the anchor is required: a batch may only edit the account the ticket names.
An anchor-less ticket (filed before `create-ticket`'s `PROFILE_ANCHOR_REQUIRED`
gate covered this action type) writes no tag and stays waiting-on-us, so the
count in the report tells you how much of the backlog predates the gate.

`remove: true` is a *known* key on purpose: a removal must be **declared** so it
can be refused, because a removal left out of the manifest would let a mixed
request close as `complete` while the credit the customer asked to be taken down
is still on their profile. Removals are core #10310 territory — a named human
runs them from their own login, and no automation may do it.

## What a run does

1. **Read** open `action:bulk-credit-change` tickets, oldest first, 3 per run
   (cap). Tickets already carrying any `customer-outcome:*` tag are skipped, and
   a ticket this drainer has already attempted (state
   `/var/lib/hydra/bulk-credit-change/attempts.json`) is skipped so unparseable
   tickets cannot eat every run's budget. That skip is keyed on a **fingerprint
   of the ticket text**, not just the id: support can add the `details.bulk_rows`
   manifest to a ticket that was prose-only this morning, and a permanent skip
   would leave a now-executable ticket open and untagged forever. Same text, same
   verdict, no re-try; changed text, one fresh attempt. An entry written before
   fingerprints existed is re-tried once and re-recorded. `--ticket <id>` obeys
   the SAME guard:
   naming a ticket that already carries an outcome (e.g.
   `customer-outcome:verification-required`, a human decision) refuses it with a
   message instead of overwriting that decision with `complete`. Overriding is
   `--allow-tagged --operator <email>` — a named human, printed loudly, because
   that flag rewrites someone's recorded decision. The operator must be an email
   address **and** on the reviewed allowlist
   `policies/credit-override-operators.txt` (a bare word, or a well-formed
   address nobody has authorized, is refused with exit 1), and the override is
   written to the ledger as a `phase: "override"` row — operator, ticket, the
   outcome tags it replaced, and the new one — BEFORE the tag is touched.
2. **Validate every row before any write** — track exists and is not
   deleted/merged, profile exists and is not merged, and **the profile already
   holds a credit on that track** (this is an edit; a credit that is not there
   is a *claim*, a different queue). One bad row refuses the whole batch: zero
   writes, `customer-outcome:blocked`, one internal comment naming the failures.
3. **Apply sequentially**, one row at a time: compare-and-set against the role
   list read during validation, then `POST /admin/track/<t>/profile/<p>/credits
   {"role": …}`, then read back until the role shows (6 attempts / 2s apart). A
   row that fails after the write boundary **stops the batch** immediately and
   the completed rows stay recorded.
4. **Tag, and only tag.** All rows verified → `customer-outcome:complete`.
   Anything less → `customer-outcome:partial` plus ONE internal comment naming
   only the rows that did not land.

In shadow the buckets are `complete` (rows already held), `would-complete` (rows
would be written), `unparseable` / `too-many-rows` / `row-invalid` /
`missing-profile-anchor` (intake defects, no tag) and `removal-refused` (tagged
`blocked`). A dry run never reports `partial` for a ticket it simply has not
tried yet.

A **partial is never a close**. It is a first-class outcome: the reconciler
(`scripts/clickup-reconcile.py`, PR 1706) reports it and leaves the ticket open
so it lands in the SLA digest. Only `complete` reaches `resolve-notify.py`, whose
allowlist this PR extends with `bulk-credit-change` reusing the *same approved
constant* as every other completed action type — placement, not new wording.

This path **never writes a ClickUp workflow status** and **never messages the
customer**: no row count, no per-track list, no timeline.

## Baseline measured before arming (2026-11-03)

Read-only scan of list `901000600160` with `tags[]=action:bulk-credit-change`:

| Measure | Value |
| --- | --- |
| tickets carrying the tag | 100 |
| non-terminal (what this drainer scans) | 99 — 2 `to do`, 45 `waiting`, 52 `in progress` |
| description contains a `---ACTION-REQUEST---` block | 93 |
| description contains `details.bulk_rows` | **0** |
| already carrying a `customer-outcome:*` tag | 1 (`verification-required`) |

So the executor is not the blocker: **intake has never emitted the row list.**
The refusals name the keys these tickets *do* carry (`customer_name`,
`tracks`, `requested_role`, `track_urls`, `requested_correction`, …), which is
the intake fix, and none of them is coerced into rows — guessing which track
gets which role is exactly how the wrong credit lands on the wrong profile.

Until the intake emits `bulk_rows`, an armed run would refuse every ticket it
sees. That is the honest outcome (no tag, no write, counted in the report), and
it is why the cron ships unarmed: the shadow report is the case for arming, and
today it argues for the intake change first.

## Safety rails (all in `scripts/clickup_drain/write_path.py`)

| Rail | Value |
| --- | --- |
| Tickets per run | 3 |
| Rows per ticket | 25 |
| Credit writes per UTC day | 100, counted in `/var/lib/hydra/clickup-drain/writes.json` — the fleet-wide drain budget, so any sibling drainer shares it (none exists in this repo yet) |
| Lock | one flock, `/var/lib/hydra/clickup-drain.lock` (whole drain surface) |
| Kill files | `/etc/hydra/clickup-drain-bulk-credit.disabled` (this queue) **or** `/etc/hydra/clickup-drain-credit-correction.disabled` (reserved: any sibling drainer checks the same pair) |
| Ledger | `/var/lib/hydra/bulk-credit-change/ledger.jsonl`, one row per write with the before/after role list |
| Dry run | the default; `--apply` is required to write anything |
| Attempts state | `/var/lib/hydra/bulk-credit-change/attempts.json` — keeps an unparseable ticket from eating a slot every run, keyed on a fingerprint of the ticket text so a ticket that gains a manifest is retried; pruned to the open queue |
| Holds state | `/var/lib/hydra/bulk-credit-change/holds.json` — tickets parked for manual reconciliation because writes landed and the request was then rewritten; released only by `--clear-hold <id> --operator <email>` |

The shared cap and the single lock are deliberate: "we are editing customer
credits unattended" is a property of the fleet, not of one queue file.

The kill files are re-checked at **every write boundary** (`reserve_write`), not
only when the lock is acquired. A kill file is an emergency stop, and ops
creates it while a run is already holding the lock: a check that only ran at
acquisition would let an armed run POST the rest of its batch (up to 3 tickets x
25 rows) after the stop was requested. A `DrainBlocked` raised there stops the
whole run and `main` renders the stop reason; the rows that already landed stay
in the ledger.

## When the admin API is down vs when a row is wrong

The distinction is load-bearing, and it is enforced in code:

| Situation | What happens |
| --- | --- |
| the API answers 5xx / 408 / 425 / 429 on a READ, the wrapper times out or returns non-JSON | `Unavailable` — the run STOPS, the ticket keeps no tag, and the next run retries it |
| the profile read answers 401/403, a wrapper failure, or a body we cannot parse; the credit list comes back malformed | `Unavailable` — unreadable admin state says nothing about the request, so the run stops and the ticket keeps NO tag. `blocked` is reserved for a CONFIRMED request defect |
| a row's profile 404s on two reads, or the profile holds no credit on that track | refusal — the WHOLE batch is refused, `customer-outcome:blocked`, and a human fixes the manifest |
| the profile read succeeds but its `/credits` sub-resource 404s | `Unavailable` — the two reads disagree, so this is inconsistent admin state, not proof the request is wrong. Recording it as an invalid row would tag `blocked` and no later run would ever retry a valid ticket |
| `/admin/track/:id` 404s on two reads while the profile's credit list shows a credit on it | `Unavailable` — the two reads disagree (that route 404s when its own catalog read fails), so this is a broken read, not a bad row; the run stops and a human looks at the stale credit vs the catalog |
| the POST succeeds but the read-back cannot be read (including a window that starts readable and ends unreadable) | ledger records intent + `unverified`, no tag; the next run re-verifies and tags `complete` if the role is there. Only a read that SUCCEEDED can say "the role is not there" |
| a POST answers 408/425/429/5xx (or the wrapper cannot classify it) | `Unavailable` — the write may have landed, so the ledger records `unverified` and the ticket keeps NO tag; the next run re-reads and tags `complete` if the role is there |
| a POST answers 401/403 | `Unavailable` — our credentials could not answer, so nothing was written; the ledger records `unverified` with that reason and the ticket keeps NO tag. Only a real refusal (400/409/422) is `failed`/`partial` |
| the shared budget for today is spent | `DailyCapReached` — the run stops with the ticket UNTAGGED; rows that already landed stay in the ledger and tomorrow's run resumes the ones still missing (a `partial` tag here would freeze a batch that was never written) |
| the write budget file is corrupt | `DrainBlocked` — the run stops rather than reading "0 writes today" out of an unreadable budget |
| the write budget is dated in the FUTURE | `DrainBlocked` — a past date is yesterday's budget and today starts at zero, but a future date means the clock moved backwards under a budget that already recorded spend; reading it as zero would hand out another full day on top of writes that really happened |
| the write budget's `date` is missing or not `YYYY-MM-DD` | `DrainBlocked` — a budget we cannot date is not a budget we may read as zero spent |

"That row is wrong" is a fact about the request; "we could not read" is a fact
about the moment. Turning the second into the first is how a transient outage
permanently parks a customer's ticket.

The ledger carries one `phase: "intent"` row before every POST and one
`phase: "result"` row after it, so a crash between them cannot leave a credit
changed with no trace. Two rows may target the same credit with different roles:
after the first add lands, the second row's expected pre-image is advanced, so
the compare-and-set does not refuse our own write.

The internal comment is posted BEFORE the outcome tag at every site, because a
tagged ticket is skipped forever: a tag whose explanation never posted could
never be explained.

`already` is re-read, never remembered: a row that validation found satisfied is
read again before the run calls it done, and if a human removed that role meanwhile
the batch stops instead of tagging a ticket complete with the requested role
absent. A non-2xx from the POST is only `failed` when it is a real refusal
(400/409/422); a 408/425/429/5xx may have landed, so it stops the run untagged.

`is_unanswerable_status` in `write_path.py` is the ONE predicate for "the admin
could not answer" (408/425/429/5xx, 401/403, an unclassifiable status), and both
the read path and the write path use it. Two copies of that classification drift,
and the drift shows up as a status that is retryable on a GET and terminal on a
POST.

## A ticket edited mid-run is a different request

The batch is planned from the snapshot the scan read, and validation takes real
time (an admin read per row). Support can rewrite the ticket while that runs:
track A/Producer becomes track B/Mastering. Applying the rows we validated would
edit credits nobody is asking for any more, and the outcome tag would then
describe the OLD request on a ticket that now asks for something else.

The same guard covers the `blocked` refusal for a removal request: that branch
comments and tags from the snapshot, so it re-reads first. If support rewrote a
removal ticket into a valid add request after the scan, tagging `blocked` would
answer a request nobody made and the next scan would skip the real one forever.

The window is open at both ends, so `ensure_ticket_unchanged` runs **twice**:

- **before the first write**, after validation (nothing has happened yet), and
- **before the outcome tag**, after the batch (a POST plus a read-back per row
takes real time, so support can rewrite the manifest mid-apply — the rows we
just wrote are then the OLD request, and tagging `complete` would let the
reconciler close and notify on a request we never executed).

Both compare the description digest with the snapshot's. A mismatch raises
`TicketChanged`: the run reports the ticket as `changed` (exit 2), tags nothing,
and records no `attempts` entry. A failed re-read is an outage, not a verdict, so
it raises `Unavailable` and the ticket stays untagged for the next run.

### A rewrite AFTER a write is a hold, not a retry

Before the first write, `changed` is self-healing: nothing happened, so the next
run reads the new text and does the right thing. After a write it is not. If the
old request added Producer to track A and support then rewrote the ticket to
Mastering, leaving it merely untagged means the next scheduled run applies the
NEW manifest, tags `complete`, and the reconciler closes and notifies — while the
unintended Producer credit is still on the customer's profile. The tag would be
true about the new request and silent about the damage.

So a `TicketChanged` raised at the pre-tag check, when at least one row was
actually posted, writes a **manual-reconciliation hold** to
`/var/lib/hydra/bulk-credit-change/holds.json` (ticket, `run_id`, reason, and the
rows that landed with their after-roles). Every later run refuses a held ticket —
both the scan and an explicit `--ticket` — and the report carries
`held for manual reconciliation: N`. The hold is durable state, not a log line,
because the failure it prevents is the *next* run, not this one.

The check runs on **both** exits from the batch. A batch that dies mid-flight (an
outage, the daily cap, a kill file) can still have posted rows, and the ticket can
have been rewritten while it ran — so the failure path needs the same check, or
the next run applies the NEW manifest and tags `complete` over the old credit.
`apply_batch` therefore hands the caller the rows it *attempted*, not just the
ones it finished: a POST that raised may still have landed, and "we cannot claim
the profile is untouched" is enough to need a human. On that path the original
exception is what gets reported — an outage is retryable, and replacing it with
`changed` would hide why the batch stopped.

A re-read that **fails** parks the ticket too, once we have written. We cannot
tell "the ticket is unchanged, ClickUp just blipped" from "support rewrote it
while we were writing", and the two have opposite safe answers: retrying is right
for the first and closes over an unintended credit for the second. The cost of
holding is a human clearing a hold that may not have been needed; the cost of not
holding is a customer's profile carrying a credit nobody asked for. Before any
write, a failed re-read records nothing — there is nothing to reconcile.

The tag itself re-checks the fingerprint. `replace_customer_outcome` reads the
ticket one last time before writing, and that read is the only one that sees the
ticket as it is at tag time — so it compares the fingerprint there too, not just
the outcome tags. Without it, a rewrite landing between the pre-tag check and the
tag would still get `complete` for the old request, and the next scan would skip
the new one. A mismatch raises `TicketChanged`, which the caller turns into the
same hold as any other post-write rewrite.

Releasing it is a human decision, so it needs a named human:
`--clear-hold <ticket_id> --operator <email>` (repeatable) removes the hold and
writes a `phase: "hold-cleared"` ledger row carrying the operator, the hold's
`run_id` and its reason. That row is written even in a dry run — it records a
decision, not a credit write — and it is written **before** the hold is dropped:
the other order has a window where the ticket is eligible again and no durable
record of who released it exists, so a failed ledger write would leave the next
run free to apply the replacement manifest with nothing to explain why. An intent
row that never got its release is visible; a release that never got its row is
not. A hold with no operator is refused, and a hold that is never cleared keeps
the ticket out of every run, which is the point: the profile needs a person to
look at it.

The operator must be on the **same reviewed allowlist** as `--allow-tagged`
(`policies/credit-override-operators.txt`), not merely a well-formed address.
Releasing a hold hands the ticket back to the next armed run, which applies the
replacement manifest — that is the same act as overriding a human's outcome tag,
and `invented@example.com` is a well-formed address. A CLI flag is a claim, not a
credential; the allowlist is the only thing that makes the claim checkable.

The path to that file is **pinned**, with no environment override. An env var
would make the list replaceable at runtime — point it at a file containing
`invented@example.com` and both `--allow-tagged` and `--clear-hold` accept an
address nobody reviewed. The list is a reviewed artifact, so the only way to
change it is a PR to the file. Tests inject a fixture through
`load_override_operators(path=...)` or by patching the path function, never
through the process environment.

Only an **absent** `holds.json` means "no holds". A file that exists but cannot be
read or parsed is a hold set we cannot see, and reading it as empty would release
every parked ticket at once — the same fail-closed rule as the write budget, for
the same reason: unreadable state is not evidence of a clean state. It raises
`DrainBlocked` and the run stops.

## A human's outcome tag outranks this drainer

The outcome guard is evaluated on the scan snapshot, so a person can label the
ticket while the batch is being applied. `replace_customer_outcome` therefore
takes the tags the run SAW and refuses to delete one that appeared since: it
raises `OutcomeConflict`, the run reports the ticket as `conflict` (exit 2), and
the ticket keeps the human's tag. The rows that landed stay in the ledger. The
only way past it is `--allow-tagged --operator <email>`, where a named human owns
the transition. Without this, a `verification-required` set mid-run could be
replaced by `complete` and the reconciler would announce a held case as resolved.

That override is audited, not just permitted: `--operator` must be an email
address, and the replacement writes a `phase: "override"` ledger row (operator,
ticket, `previous_outcomes`, new `outcome`, `run_id`) before the first tag is
deleted. An override nobody can attribute afterwards is the same as no override,
so an override with no ledger to write to is refused outright.

An audit row is only worth what the name in it is worth, so the name is checked
against `policies/credit-override-operators.txt` — the reviewed list of people
who may authorize an override. A command-line flag is a **claim, not a
credential**: nothing in the process can prove who typed it, and
`invented@example.com` is a perfectly well-formed address. The allowlist is the
bound code can actually enforce, and it fails **closed** — a missing or empty
file refuses every override rather than accepting any. Adding a person is a
reviewed PR, because it grants the ability to overwrite a recorded human
decision. This is not an approval list: credit approvals are governed by
`policies/credit-approval-automation.json`.

`previous_outcomes` lists **every** outcome tag the run removed, and the audit
covers both shapes of override because they are the same act: a tag that appeared
while the batch was running, and a tag that was already on the ticket when
`--ticket` selected it (the ordinary `--allow-tagged` case). Keying the audit on
"appeared since selection" alone would leave the second — the one an operator
actually reaches for — replacing a human's hold with no record of who authorized
it.

The swap itself is **add-then-remove**, never the reverse. A failed add leaves
the previous outcome exactly where the human put it; a failed remove leaves the
ticket carrying two outcome tags, which `customer_outcome_of` reports as `None`
so every consumer fails closed. Deleting first would let a rejected POST erase a
live decision and leave the ticket tagless — re-pickable by the next scan, with
the human's hold gone and no way for the ledger to put it back.

A `partial` comment names **every** requested row exactly once — verified,
failed with its reason, or `not attempted (the batch stopped at an earlier row)`.
A comment that silently omits the tail reads as the whole story.

## Undo: plan only, never executed here

An undo of an added role is a credit **REMOVAL**, and the deployed
`muso-admin-api.sh` refuses every credit-removal DELETE in `enforce_removal_gate`
(unless the wrapper is in dry-run mode), whatever the requester or environment
claims. So this helper has no removal capability at all — `write_path.py` exports
`add_role` and no `remove_role`, and `--revert` prints a plan:

```bash
python3 scripts/clickup_drain/bulk_credit_change.py \
  --revert /var/lib/hydra/bulk-credit-change/ledger.jsonl
```

It lists, newest first, the exact roles the ledger says were added, with each
credit's current role list, and skips roles that are already absent. Any
`--apply`/`--operator` is rejected with exit 1 (`RUN_EXIT_USAGE`): a flag that
cannot change the identity on the wire is not a human undo, and a documented
command that always fails at the wrapper is worse than no command.

Carry the printed list to a named human, who runs it from their own session via
`skills-all/muso-ops-tracks` (**Removal Requests**) — the approved path that
core's #10310 gate exists to funnel removals through. Retroactive take-backs use
`scripts/credit-retro.py` instead.

Only `phase: "result"` rows with `outcome: "verified"` are undoable; intent rows
and `unverified` rows are skipped, because removing a write that may never have
landed is its own guess.

## Arming (captain decision)

1. Run it by hand in shadow and read the manifest hit rate. If most open tickets
   are `unparseable`, the fix is the support skill, not a live executor.
2. Append `--apply` to the cron's `argv`, set `"enabled": true`, and give it a
   `delivery` target (it ships with `"mode": "none"` so shadow runs are silent).
3. ARMING IS NOT A MERGE. The standing merge authority covers shipping the code.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | clean, including "nothing to do" and "kill file present" |
| 1 | usage / env error |
| 2 | a ticket stopped mid-batch (`partial` — look at it), a human labelled it mid-run (`conflict` — their tag stands), or the ticket was rewritten mid-run (`changed` — nothing was written, or a hold was recorded if rows had already landed) |
| 3 | the run could not proceed and nothing was tagged (lock held, admin unreachable, today's shared write budget spent — all of these retry later) |
