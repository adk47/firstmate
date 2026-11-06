# ClickUp `action:data-deletion` drainer

`scripts/clickup_drain/data_deletion.py` — hourly. It closes a ClickUp
`action:data-deletion` ticket **on the GDPR register's written confirmation**,
never on the page being hidden, and reports the register's overdue count in the
same line as the board numbers.

Why it exists (2026-10-29 captain: *"make sure the GDPR profile removals work end
to end"*; 2026-11-03: *"can you help the system handle the clickup tickets"*):
measured on the live register, 374 rows / 372 open, **159 past the statutory
30-day date**, `ask_sent_at` on **zero** rows, `confirmed_at` on **one** — and
156 open `action:data-deletion` tickets that nobody closed even after the erasure
completed. The register is the legal record; the board is the work queue.
Nothing joined them.

## The rule

| register row | board effect |
| --- | --- |
| `confirmed_at` set (the letter went out) | `customer-outcome:complete`, then status `resolved` |
| `hidden_at` set, **no** confirmation | **nothing** — reported as `hidden-not-confirmed` |
| `status='closed'`, **no** confirmation | **nothing** — reported as `closed-no-letter` |
| past `due_at`, no confirmation | **nothing** — counted in `OVERDUE` |
| `class` in `legal_threat`, `dmca_takedown` | `customer-outcome:blocked`, status unchanged (or nothing, if a letter is on record) |

`outcomeChannelFor("data-deletion") = erasure`: the customer-visible outcome is
the register's `erasure_sends` confirmation, not a ClickUp status and not the
hide. Hiding is step 3 of 5 (`hidden_at`: 410 + noindex read back); the letter is
step 5. Closing on the hide would tell the board that a removal is done while the
customer has heard nothing.

Two things the dispatch spec asked for, corrected against the register's code:

1. **The `status='closed'` conjunct selects zero rows forever.** `run.confirmations()`
   iterates `store.all("open")` and *skips* rows that already carry
   `confirmed_at`, i.e. a confirmed row deliberately stays `open` in `status`;
   the only writer of `status='closed'` is the markdown register's COMPLETED
   marker. So the completion test is `confirmed_at` alone, and a CLOSED row
   without one is reported, never closed. Live evidence both ways: row 13 is
   `closed` with no confirmation, row 19 is `confirmed_at` with `status='open'`.
2. **The "one confirmed row → one ticket" canary does not exist** — that one
   confirmed row carries no ClickUp id. So the write path is proven by
   `--probe <task>`: add a production outcome tag to a real ticket, read it back,
   remove it — all in one run, both halves in the ledger.

## What "close" costs, and why it is two writes

`customer_outcome.customer_complete()` is true only for a ticket that is **both**
terminal and carries `customer-outcome:complete`. Tagging alone would leave every
ticket open forever, so a confirmed row gets the tag and then the status
`resolved` — in that order, so a crash in between leaves an honestly labelled,
still-open ticket rather than a closed ticket with no outcome. An outcome tag is
**replaced, never added**: `customer_outcome_of()` returns `None` when a ticket
carries two outcome tags, so `POST`-ing a second one would silently unset
somebody else's outcome (`scripts/uvn-under30-cron.py:replace_customer_outcome_tag`
is the same rule).

The half-state is finished, not frozen: a run that finds `customer-outcome:complete`
on a ticket that is still open closes it. That is what a crash between the two
writes leaves behind, and "already tagged" must never make an interrupted
completion permanent.

A `blocked` tag does **not** change the status: counsel's case is not finished by
anything this drainer can do.

## Relationship to the ClickUp reconciler

`scripts/clickup-reconcile.py` is the default closer — it reads a terminal marker
off the ticket and writes `resolved` with an audit comment. It cannot make *this*
decision, because the evidence (the register's written confirmation) is not on the
board. So the drainer closes as a specialization of the reconciler's two shapes:
label first, close second, and leave the reason on the ticket as an internal
comment naming the register row (`notify_all: false` — nobody is emailed; the
customer's only message stays the register's own confirmation). Once the
reconciler is deployed, both converge on the same status; neither closes on
evidence it did not read.

## Operating it

```bash
# what it would do (default; no writes, no Slack post, no customer message —
# add --notify-dry-run if you want the digest posted anyway)
scripts/clickup_drain/data_deletion.py
scripts/clickup_drain/data_deletion.py --json

# write tags (200/run cap; skips ticket statuses that are already terminal)
scripts/clickup_drain/data_deletion.py --apply

# prove the write path end to end on one live ticket, then undo it
# (writes `customer-outcome:blocked` — the weaker claim — so a crash between the
#  write and the revert cannot leave a live ticket saying the erasure is done)
scripts/clickup_drain/data_deletion.py --probe 869abc123

# take back everything a run wrote
scripts/clickup_drain/data_deletion.py --revert /var/lib/hydra/clickup-drain/data-deletion.jsonl

# offline board scan (no ClickUp token needed)
scripts/clickup_drain/data_deletion.py --board-json dump.json
```

Exit codes: `0` ok (including "nothing to do"), `2` a read failed so nothing was
written, `4` the kill file refused the run, `5` a write did not land (the request
errored *or* did not read back — this is what makes the unit's `OnFailure` page
fire when the best-effort Slack alert does not) — also used when a ticket carries
conflicting decisions and was deliberately not written, `7` a Slack message the run
was told to deliver did not go out (the writes are fine; the report is not, and the
exit code is what the unit's `OnFailure` and the cron watchdog read), `6` `--revert`
could not undo everything it recorded.

**Kill switch**: `touch /etc/hydra/clickup-drain-data-deletion.disabled` — refuses
every write *and* every page on the scheduled apply/probe path, and says so in the
journal. It does **not** block an explicit `--revert`: that is an emergency rollback
of writes this drainer already made, and a switch that also disabled the undo would
leave a bad run on the board with no way back. `--revert` is dispatched before the
kill-file check for exactly that reason.

The switch is checked **before** the board and register reads, and the unit carries
`SuccessExitStatus=0 4`. Both halves are load-bearing: the check has to come first
or a ClickUp/register outage while the switch is on exits `2` and pages through
`OnFailure`, and the whitelist has to exist or the (correct) exit `4` pages the same
way. Every other non-zero exit still fails the unit. `scripts/tests/install-aux-units-clickup-data-deletion.bats`
pins both the whitelist and the fact that only `0` and `4` are on it.

**Ledger**: `/var/lib/hydra/clickup-drain/data-deletion.jsonl`, one JSON object
per attempt *and* per result (`action: add|remove|resolve`), written before the
request and confirmed by a fresh `GET` afterwards. A write that landed is
therefore always revertible, even if the process died between the two, and
An interrupted run (`result: attempted` with no result — the process died between
the ledger line and the request) is read as *unknown*, not as nothing: `--revert`
looks at the ticket, removes the tag only if it is really there, and reports
`already gone` when the write never landed.

`--max-writes` (default 200, hard cap 200) counts **API mutations** — a tag delete,
a tag add, a status PUT, a comment — not tickets. One completion over a conflicting
outcome tag is four, and **one per stale outcome tag plus three** when a ticket
carries several (`replace_outcome` removes every outcome tag that is not the
desired one) — so a per-ticket cap would have let 200 tickets issue 800 requests.

**The audit comment is a debt, not a best effort forever.** A close that landed is a
fact, so a failed comment POST never reopens the ticket or blocks the run's other
work — but a `resolved` ticket with no note saying why it closed is exactly the
"automated close indistinguishable from a human's" this drainer exists to avoid. So
the close exits 5 (`comments_still_failed`) and the note is retried on the next run
from the ledger (`comment_debt()`), which is the durable record of what failed. The
retry re-reads the ticket and posts only if it is still terminal AND still carries
`customer-outcome:complete`; anything else is `skipped` with the reason, because a
comment is a claim about *this* close. A success retires the debt, so the note exists
exactly once.

**An unconfirmed close owes a note too.** `resolve_task()` PUTs `resolved`, reads the
ticket back, and only then comments. If ClickUp accepts the PUT and the read-back fails —
or the process dies between the two — the ticket is closed with no note and no comment
row to fail, and the next scan skips a terminal ticket. The ledger's `action: resolve`
row with `result: readback_missing` or a bare `attempted` is therefore also comment
debt, and the note is posted once a fresh read confirms `resolved` plus exactly
`customer-outcome:complete`. A `restore-status` record retires that debt, because a
reverted close owes no comment.

**A report that did not go out is not a green run.** Every Slack result is checked
(`deliver()`); a failure exits 7. The hourly unit is the only thing that puts the
register's overdue count in front of a human, and a job whose report silently
vanishes while it exits 0 every hour is worse than one that fails loudly.

**One ticket, two register decisions → nothing is written.** A ticket can be linked
to several register rows (a re-created request re-points its keys), so it can be
`complete` from a confirmed erasure row and `blocked` from an open counsel row at the
same time. Each label is a claim about the other row, and writing both leaves two
`customer-outcome:*` tags — which the shared reader answers `None` for, i.e. the
ticket stops saying anything. Both decisions are dropped, the ticket is named in the
digest as `CONFLICTING`, paged to `#clio_devops` with its register rows, and the run
exits 5. One of the links is wrong; that is a human's call.

**The ticket is re-read immediately before every write, and only an OPEN status may be
written to.** The scan decides what to *consider*; a fresh `GET /task/{id}` decides
whether that is still true. Without it a human who removes `action:data-deletion` between
the scan and the write would watch the drainer label their reclassified ticket
`customer-outcome:complete` and close it; a ticket that changed is `skipped_untagged`
naming the tags it actually carries, and one that cannot be re-read is `unreadable`
(exit 5). The reads cost no mutation budget. `execute()` and the read-back recovery both
close through `resolve_task()`, which **refuses any ticket whose status was not observed
in `to do` / `in progress` / `waiting`** — the gate lives in the only function that can
PUT `resolved`, so no call site (including the interrupted-completion branch) can bypass
it; anything else (`archived`, a custom status) is `NOT OPEN (not written)`, counted in
the digest as `not-open`, and never written.

**A `duplicate` register row decides nothing.** The register re-points a duplicate's keys
at the row it keeps, but the retired row can retain the ClickUp id, so the counsel branch
would label the surviving request's ticket `blocked` and replace its real outcome on a
retired row's evidence. Duplicates are skipped before every decision and still reported as
`attention`.

A dry run and a kill-file run are read-only: neither ages the intake-gap counter
(so two previews cannot push a real run to its third strike) nor posts anything.

`OVERDUE` is the register's own number, and the register's watchdog counts only
`open` rows — so a row a human closed WITHOUT a written letter leaves the legal
clock entirely. It is not folded into the count (two systems publishing different
totals is how the board and the register drifted apart); the digest names those rows
explicitly, with that reason, whenever one of them is past its date.

`--revert` refuses a ledger it cannot fully read (missing, unreadable, or a
crash-truncated line) rather than reporting "nothing to undo", and a removal the
read-back could not confirm is retried on the next run instead of being counted as
done. A ticket whose outcome tag could not be removed keeps its status (`status kept (tag
still on the ticket)`): reopening it while `customer-outcome:complete` is still
attached makes the next apply run close it again. It also puts back the status a
run changed — but only on a ticket still
sitting at the `resolved` this drainer wrote. A ticket a human has since moved is
reported as `left_for_human` and not touched, because a revert that reaches past
its own write is a time machine that undoes somebody's work. `resolved` alone is not
enough to prove the close was ours: a human can re-resolve a ticket we already
reopened, and the status would look identical. So the ticket's own
`date_closed`/`date_done` is ordered against the close record's `at` (five minutes of
slack for clock skew and a slow request), and a close that came later is
`left_for_human` too. The restore is also ledgered as `attempted` **before** its PUT,
so a restore that lands and then loses its result record cannot leave the close
looking active for the next revert to act on: replay keeps the debt while the
`attempted` row is unsettled, and the next revert **pays it** when a fresh `GET`
shows the ticket already at the target status. Without that settlement the debt
stayed live forever, and a human re-resolving the ticket inside the five-minute
slack could have that newer decision reopened by a later revert.

**An interrupted restore is refused, not finished.** If a revert wrote `attempted`
and died before its result, the ticket's current status cannot be attributed: it is
`resolved` either because our restore never landed or because a human re-resolved it
after ours did, and the close-time guard cannot separate those (a human closing
inside the five-minute slack looks exactly like our own close). So the next revert
reports the ticket as `left_for_human` with "a restore was interrupted" and touches
nothing. The debt stays live until a human settles it — the one mistake this path
must never make is reopening somebody else's decision.

That refusal is also why **only a `restored` restore retires the audit-comment
debt**. An `attempted` row is written *before* its PUT, so a revert that dies
between the two leaves the ticket `resolved` with no note; retiring the debt on
that row would mean the next hourly run saw no debt and never posted the
register-row explanation. `failed` is the same: the PUT errored, so the close is
still there and still owes its note. The retry re-reads the ticket before posting,
so a debt whose restore *did* land is skipped there rather than asserted onto a
reopened ticket.

**The ledger is validated before the first write, not after it.** `execute()` appends
to the ledger, and `--revert` refuses a file it cannot fully read — so discovering a
crash-truncated line *after* the writes would leave the new closes recorded in a
ledger nothing can undo. A run that finds the ledger unreadable writes nothing and
exits `2`. A missing ledger is fine: a first run has none.

**A write that definitively did not land is retired, so a revert cannot claim a tag
somebody else added.** `add_tag()` records `attempted` before the POST and `failed`
only after a read proved the tag is not on the ticket, so `failed` is a measured fact
and the replay drops the pair. Without that, the `attempted` record stayed live and a
later writer's `customer-outcome:complete` looked like ours — `--revert` DELETEd it.
Only `failed` retires a pair: `readback_missing` and a bare `attempted` (the crash
window) stay live, because the tag may really be there and the revert must look.

**A revert restores the outcome it replaced — for a `blocked` write as well as a
completion.** The prior tag comes from the removed write's own `before` snapshot in the
ledger (a `blocked` replacement closes nothing, so the close records know nothing about
it), is re-added, and is read back. It is **not** put back over a newer decision: if the
ticket carries a different outcome tag now, that is a later answer to the same question
and the revert reports `outcome_kept`. A re-add that does not read back is
`outcome_not_restored` and exits 6, naming the tag to repair by hand. The restore itself
is ledgered in `mode: revert`, and replay ignores those records, so running `--revert`
twice leaves the restored tag in place instead of deleting the undo. A replacement that
DELETED the old tag and then failed to write the new one leaves the ticket with no
outcome and nothing of ours to remove; `replace_outcome()` records what it replaced on
the add record (`replaces`), so a failed tail add is restored too, and a tag the read
proved absent does not make the ticket look like it still carries our outcome.

**The alert names which state each ticket is in**, because they need different actions:
*a write that did NOT LAND* (a 200 read showed no tag — these are not labelled), *a write
that could NOT BE CONFIRMED* (the confirmations failed, so the tag MAY be on the ticket —
look before re-running or reverting), *labelled but NOT closed* (still open, the next run
finishes it), and *got the tag but left `action:data-deletion`* (the tag is ON it; check
what it is about before reverting). Telling an operator "not labelled" when the tag is
sitting on the ticket sends them away from the thing they have to deal with.

**A lost response is not evidence of absence, and the read decides.** ClickUp can
apply a write and then drop the connection (or answer 5xx after committing), so a
`TimeoutError` on a POST/PUT/DELETE says nothing about whether the write landed.
`add_tag()`, `remove_tag()` and `resolve_task()` therefore re-read the ticket on any
exception or 5xx and report what the read shows — `written`/`removed`/`resolved` when
the change is there, `failed`/`still_present` when it is not, `readback_missing` when
the read itself failed. This is not politeness: both halves were real bugs. A lost PUT
recorded as `failed` made `comment_debt()` believe the next run's write path owned the
close, but the ticket was already `resolved` and an hourly scan skips a terminal
ticket, so the audit note was never posted and nothing was left to retry. A lost POST
recorded as `failed` made the probe conclude "nothing was written" and skip cleanup,
leaving `customer-outcome:blocked` on a live ticket it had just damaged. The
ambiguity is resolved in the primitive, not at each call site, so a new caller cannot
reintroduce it.

**Register**: opened with SQLite `mode=ro`. This module cannot create or edit a
register row even by accident — identity verdicts and the hide decision live in
the register, in exactly one place.

## Reading the digest

One line, every run, to `#cs_chats` (`--slack-channel`):

```
*data-deletion drainer* (apply) · register 374 rows / 372 open / 1 confirmed (1 with no ticket) /
0 hidden-not-confirmed / 1 closed-no-confirmation · board 249 tickets / 156 open · OVERDUE 159
(privacy_erasure 120, legal_threat 24, ...) · →customer-outcome:complete 1 / →customer-outcome:blocked 59 /
... · writes 1 written, 0 already tagged, 0 terminal, 0 failed, 0 readback-missing, 0 capped
```

A second line names the overdue rows and **the tickets behind them**, so the board
number and the legal number can never again be reported separately and read as
unrelated facts.

## What it will never do

- **Send the customer anything.** `data-deletion` is not in `resolve-notify.py`'s
  allowlist and must stay out: the register's confirmation *is* the message. The
  module imports no send code (`tests/test_clickup_drain_data_deletion.py`
  asserts no import of `gdpr_pipeline`, no Intercom/Gmail/SMTP string literal).
- **Create a register row.** An open ticket with no register row is emitted as a
  work item (`<state>/intake-gaps.jsonl`, `owns_retry: gdpr-pipeline.py tick`)
  and reported; the register's own intake owns that retry. A gap that survives 3
  hourly runs pages `#clio_devops`, because then the register's retry is not
  fixing it.
- **Close a ticket on anything but the register's written confirmation.** A
  `resolved` status is only ever written straight after a `complete` tag that
  read back, for a row whose `confirmed_at` is set.
- **Tag anything but `customer-outcome:complete` / `customer-outcome:blocked`.**
  `VALID_OUTCOME_TAGS` is the contract; an unknown tag raises before the write.
- **Close a `legal_threat` / `dmca_takedown` ticket.** Those go out by letter from
  counsel.
- **Tag an overdue request `complete` or `not-applicable`.** It has no
  confirmation, so it has no outcome yet.

## Deploy

`scripts/install-aux-units.sh` installs `clickup-drain-data-deletion.service` +
`.timer` (hourly at `:25`, `RandomizedDelaySec=180`, `TimeoutStartSec=900`) with
`--apply` and `OnFailure=hydra-unit-failed@%n.service`. It depends on
`scripts/lib/clickup_client.py` and `scripts/lib/customer_outcome.py` (both on
`main`); the register it reads is produced by the erasure pipeline (hydra PR
#1629), which lives at `/var/lib/hydra-gdpr/erasure.sqlite`. The script gates on
those files, so install fails loudly rather than scheduling a unit that would
crash hourly.

Rollback: `systemctl disable --now clickup-drain-data-deletion.timer`, then
`--revert` the ledger if the tags must go too.

## 2026-11-03 measurements (before this landed)

- register: 374 rows, 372 open, 1 closed, 1 confirmed, 27 hidden, 0 `ask_sent_at`;
  159 with `clickup_ids`.
- 160 open rows past `due_at` with no confirmation (159 on the earlier scan).
- by class (open): privacy_erasure 252, legal_threat 59, dmca_takedown 30,
  privacy_access 22, cancel_intent_mentions_deletion 7, not_erasure 2.
- board: 249 `action:data-deletion` tickets on list `901000600160`
  (`include_closed=false`; 93 of them already `resolved`) → 156 open. The
  dispatch brief's "138 open" was a different measurement window, not a
  contradiction: the count moves daily.
