# Item 5: where each outcome lands

Read 2026-11-15 15:30Z to 15:40Z, on `main` `f910a2f8e` and on node-8 (deployed
`be9e53e6e`). node-8 was read only. A sink is the thing that takes a row out of a
state. A state with no sink, or whose sink is a command or a list a person runs or
reads, is a human queue.

This is a survey, not an audit. What I traced to its consumer is in the tables. What
I only found by its name is listed at the end as not traced.

## The scale drain's own outcomes

Counts are the plan of 2026-11-15 15:02Z over 102,517 pending requests, deployed code.

| outcome | rows | what takes it out | a person? |
|---|---|---|---|
| `approve` | 3,395 | `apply` writes core `approved`. Nothing has landed: the ledger holds 3,326 intents, all `planned`. The write needs core PRs 11378 and 11379 deployed, the `credit-automation` role, an identity file and `/etc/hydra/scale-drain.token`, and nothing creates the token | yes, until those are placed |
| `close_duplicate` | 0 | `apply` writes core `rejected` through `conditional-status`, and core sends its rejection notice on that move. No row has ever been planned or written: the 15:02Z plan has none and the ledger has none, because no pending request names a request as its duplicate (every `duplicate_of` on the replica is a map of profile credits, 856 pending). https://github.com/Muso-AI/hydra/pull/2025 removes the outcome | no |
| `ask` | 97,074 | `scale_drain.py asks --plan P --out FILE`, then `need_asks.py build --from-drain FILE`. No cron and no timer runs either command | yes |
| `cannot_confirm` | 988 | nothing. A ledger row: no status write, no message, no mark | yes |
| `unmatched` | 1,060 | nothing. Counted in the plan and never recorded | yes |

Rows already in the drain's ledger (`/var/lib/hydra/credit-review/drain.sqlite`) that
no current plan names:

| rows | written | what takes it out |
|---|---|---|
| 1,324 `queue_tier2` (1,165 precedent, 159 proof verdict) | 2026-11-11 18:41Z | nothing. Each has a `told` row and no message was sent |
| 3 `reject` | 2026-11-14 20:34Z, the rehearsal | nothing |
| 91,071 `ask` | 2026-11-11 to 2026-11-14 | as `ask` above |

`scale_drain.py tier2-queue` still parses and exits 0. It lists no row, and on every
run prints the wrapper command for a tier-2 approver to reject a request. No cron, systemd unit or script on node-8 calls it: the name
appears only in `scale_drain.py`, its doc, `AGENTS.md` and review copies under
`/opt/hydra/workspaces` and `/opt/hydra/audit`.

## The ask sender

The one scheduled sender of asks is `credit-ask-tick.timer` on node-8, every 30
minutes, running `/opt/hydra/scripts/credit-ask-tick.sh`.

- The script is not in git. `main` mentions it only in
  `data/never-asked-canary-r1/report.md`.
- It calls `need_asks build` with no `--from-drain`, so it never reads the drain's
  plan. The drain's `ask` rows reach a customer only where `need_asks` picks the same
  request by its own rules.
- It has sent nothing since 2026-11-15 08:20Z. `/etc/hydra/credit-ask-STOP` was placed
  then by lane verif-scale-driver-f1; the file says the pass ended on its one-hour
  timeout 4 times of 4, its last 3 logged passes sent 0, and it held the ledger's run
  lock for that hour. Every run since logs `STOP file present`.

## Where a customer's answer to an ask lands

3,769 asks are recorded as sent. 3,717 of them have no conversation id (they went as
email).

| what the customer sends | what reads it | reaches a decision? |
|---|---|---|
| a document | `credit-verify-proof-file` files it (hourly), `credit-proof-marker` tags the note answered, `credit-doc-verify` and stage 2 read it, `proof_reviewer.py` writes a verdict to `verify_proof_reviews` (6,674 rows, all by `ai:proof-reviewer/pr-1`, newest 14:55Z) | no. Nothing turns a read document into a core decision (`doc_approvals` has 0 rows) |
| words only | nothing. `verify_ledger`'s reply recorder returns `not_applicable` for a note with no removal date, and none of the 3,769 asks has one. `last_reply_at` is set on 43 of them; I did not find what wrote those | no |
| a link | `proof_link_intake`, read only by `credit-proof.py file-recent --links`, which no cron passes | no |

Measured on the two cohorts whose window closes first (586 contacts, read from
Intercom): 19 replied after the ask, 18 of them in words only. Under the expiry rule
those 18 expire as if they had said nothing.

`reply_due_scan.py` and `reply_ref_picker.py` are the coded path for a customer who
wrote and was not answered. `reply_ref_picks` has 0 rows, so it has not run on this
ledger. Its residual classes are `unanswered_by_code` and `jan_review`, "Jan's REVIEW
list".

## Queues that end at a person, live today

| queue | rows | sink |
|---|---|---|
| `credit-jan-tray-0700` (cron, enabled) | 66 rows on 2026-11-15, 60 and 57 the two days before | a Slack DM to Jan each morning listing the claims whose document proves them. A person evaluates proof |
| `rereview_queue` | 582, all `CONTRADICTED`, 0 resolved, newest 2026-11-15 13:46Z | none. `ledger.py` inserts; no code reads the table |
| `reviews` from `credit-review-shadow-4h` (cron, enabled) | 3,872 `NEEDS-HUMAN`, 498 `REJECT-RECOMMENDED` of 39,165 | none. Shadow: recorded, no output |
| `verify_refusal_holds` | 422 (210 `status-doc-received`, 212 `status-team-review`); 344 have a recheck date of 9999-12-31 | `intercom_reconcile.py` lifts the identity ones (78 by reason). `account-hold` (264) and `owe-proof-told-nothing-needed` (80): no lifter found |
| `verify_messages` in `attempting` | 37, campaign `first-ask-1`, 2026-11-09 and 11-10 | `attempted_reconcile.py`, which settles a row on `--confirmed-by WHO` |
| `verify_messages` in `attempted` | 1 (`uvn-status`, 2026-11-04) | the same |

## Stops that only a person clears

These are not queues of customers. Each stops a writer until a person acts, so
everything behind it waits on that person.

- `apply_queue.py` and `bulk_queue.py`: an `uncertain` send is settled only by
  `resolve --by <person>`. `apply_queue` is off on node-8 (`/etc/hydra/apply-queue.disabled`
  since 2026-11-13); `bulk_queue` is not wired.
- `decide.py`: the kill-armed marker and the write-in-progress marker each refuse
  every later run "until a human" restores or confirms.
- `doc_approve.py`: a frozen class approves nothing "until a human clears it".
- `/etc/hydra/fable-decider.disabled` (since 2026-10-29) and the other kill files.

## Not traced

Found by name in `scripts/credit_review/`, consumer not followed:

- The decider's own states. In the last 7 days `decisions` holds 260,947 `support`,
  51,216 `hold`, 46,818 `defer` and 943 `approve` rows (a row per run, so these are
  not request counts). Stage 2 takes `proof on file` holds; I did not follow the rest.
- `policy.py` returns `NEEDS-HUMAN` on five paths; `runner.py` acts on it only in
  phase `advise`.
- `status-team-review` and `team_review` as a customer-facing stage name.
- `removal_executor.py`, `decline_close.py`, `validator_reject_close.py`,
  `claim_status_list.py`.
- Intercom assignment, snooze and team routing live in `plugins/intercom`, outside
  this directory. Not read here.
- Whether the 3,717 emailed asks carry a reply address that reaches Intercom at all.
  The 19 measured replies show some do; I did not read the send path.

One thing I saw and cannot explain: `credit-proof-reviewer` is `enabled: false` in
`cron-jobs.json` on `main`, and `verify_proof_reviews` has rows written at 14:55Z
today. No systemd unit and no crontab line on node-8 names it.

## What follows

In the order these would close, each its own change:

1. `tier2-queue` goes (item 6). It has no caller.
2. `cannot_confirm` and `unmatched` need a sink: a message that says what would
   reopen the request. Until then they are the unnamed queue the first review refused.
3. The drain's `ask` rows need a scheduled consumer, or the drain should stop
   emitting an audience nobody reads. The ask tick belongs in git either way.
4. A reply in words needs a reader before any expiry is applied.
5. Jan's morning list, `rereview_queue` and the shadow reviewer's `NEEDS-HUMAN` are
   proof evaluation by or for a person. Each is a decision about what replaces it,
   not a rename.
