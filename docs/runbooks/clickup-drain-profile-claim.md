# `action:profile-claim` drainer

Captain 2026-11-03 ~22:3xZ: *"every user ticket cleared by code."* This is the
first drainer. `scripts/clickup_drain/profile_claim.py`, hourly at `:35`.

## Why this queue first

`outcomeChannelFor("profile-claim")` is `app_notification`: the claim lane's own
in-app (and email) message is the customer-visible outcome, **not** an Intercom
reply. Nothing here has to write copy to a customer, so the ticket only has to
*record* a decision that core already made. Every other queue needs someone to
say something new.

Measured on the live board (`--dry-run`). The second run (2026-11-04, 240 open)
is the one to read — it is the third measurement, after two correctness fixes:
the first run carried a global date cutoff on the claim read and under-counted
completed claims (117 complete / 89 awaiting / 12 outside-window), the second
removed the cutoff (+25 to `complete`), and the third stopped calling a
Profile-ID-less ticket with an older claim "never submitted" (26 moved out of
`awaiting-user-submission` into `ambiguous-claims`).

| bucket | n | what the drainer does |
|---|---|---|
| `complete` | **142** | tags `customer-outcome:complete` (claim `processed`, or rejected by `claim_executor` and read back as rejected) |
| `awaiting-user-submission` | **35** | tags `drain:awaiting-user-submission` — the account has no claim row in core at all; the `claim-proof-ask` campaign is what talks to them |
| `needs-identity` | 13 | nothing: the ticket's email resolves to no Muso account |
| `claim-outside-window` | 17 | nothing: the account's claim on that profile is older than the ticket and still `pending`/`rejected` |
| `awaiting-review` | 5 | nothing: pending, identity proof submitted (or ours to review) |
| `ambiguous-claims` | **27** | nothing: no Profile ID on the ticket and the account's claims do not identify one unambiguously — several inside the window, or only ones older than it. Never "never claimed": 26 of these were previously tagged that way and every one has a real historical claim (e.g. `869djhv82` → claim 24828 `processed` since 2023) |
| `claim-closed` | 1 | nothing: `closed` is neither approved nor rejected |
| `ticket-undated` | 0 | nothing: the ticket has no readable `date_created`, so there is no window and no claim can be attributed to it |

`ticket-undated` is 0 on the live board and exists as a refusal: `created_s` falls
back to `None`, which used to make the cutoff `-86400`, so every historical claim
qualified — for a profile-less ticket that attributed one unrelated old claim to
the request and could tag it `complete`. A ticket we cannot date attributes
nothing.

The tag is the *only* write. `scripts/clickup-reconcile.py` moves the ticket to
`resolved`; `scripts/resolve-notify.py` (profile-claim is in its `ALLOWLIST`)
sends the one approved "it's done" line on its next `02/08/14/20:25` tick; and
`scripts/close-resolved-conversations.py` closes the Intercom conversation when
we spoke last. For an `app_notification` class the close may legitimately never
fire because we never replied in-thread — the digest says so (5 of the 142
would-close tickets carry no Intercom link at all) instead of inventing a reply
to make the close fit.

## What it must never do

* **Approve.** `POST /admin/claiming/:id/verify` writes catalog identity and
  hydra has never called it. Approval stays a human/verification flow (and a
  future registry entry). A test fails if the route so much as appears in the
  drainer's code.
* **Write a rejection.** A coded contradiction becomes a `claim_executor` tray
  row carrying the ruling id; `scripts/credit-fable-execute.py` is on
  `check-credit-approval-automation.sh`'s NEVER_SCHEDULED list, so the drainer
  prints the command and does not run it.
* **Send a message, or write a ClickUp status.** The tag is the output.
* **Act on a partial read.** An unreadable replica read raises. "Could not read"
  is never "no claim row" — that would tag 89 customers as un-submitted on a
  broken query.

## The ladder (first match wins)

1. any claim `processed` → `complete`. Includes a claim approved *before* the
   ticket: the (account, profile) pair is the identity key, and 68 of the 80
   predated tickets measured on 2026-11-03 had exactly that pair approved, i.e.
   the profile was already theirs.

   The replica read therefore carries **no `createdat` cutoff** — it returns every
   not-deleted claim the ticket's account ever made, and the per-ticket window is
   applied afterwards in `match_claims`. A global `createdat >= min(ticket) - 1d`
   makes the historical lookup silently incomplete and reports "never claimed"
   for a profile the customer already owns (QA finding on PR #1712; the test fake
   honours a timestamp predicate so re-introducing one fails the suite).
2. any claim `rejected` **with** a `claim_executor` audit row
   (`kind=claim_decline`, `outcome=written`, `after=rejected`) → `complete`.
   Core's `profile_claim_rejected` fan-out already told them.
3. any claim `pending`/`reverted`:
   * a coded contradiction class fires on fresh facts → tray row, **no tag**
     (until the executor's read-back says `rejected`, when the next run tags it
     complete);
   * contradicted but the account gate is not cleanly `allow` → `held-for-human`,
     reported, never queued;
   * nothing submitted (`verificationLinks` has no `weblinks`/`email`) **and**
     `claim_proof_ask` recorded an ask → `customer-outcome:verification-required`;
   * nothing submitted and **no** ask → reported only. Tagging "verification
     required" for a customer we never asked is a lie;
   * proof submitted → `awaiting-review`, reported.
4. rejected with **no** executor audit row → reported (a human's Retool reject is
   not something this run can vouch for).
5. `closed` → reported.
6. no claim row → `awaiting-user-submission`.

Anything not on this list is reported, never written.

## Operating it

```bash
# what it would do right now (the default; writes nothing)
python3 scripts/clickup_drain/profile_claim.py
python3 scripts/clickup_drain/profile_claim.py --json      # same, machine-readable

# one capped live batch
python3 scripts/clickup_drain/profile_claim.py --apply --max-writes 20

# undo exactly the tags a ledger added (dry run first; it prints the count)
python3 scripts/clickup_drain/profile_claim.py --revert \
  /var/lib/hydra/clickup-drain/profile-claim.jsonl
python3 scripts/clickup_drain/profile_claim.py --revert \
  /var/lib/hydra/clickup-drain/profile-claim.jsonl --apply
```

* **Stop, now, no deploy:** `touch /etc/hydra/clickup-drain-profile-claim.disabled`
  (a `--dry-run` still works with the kill file present; only `--apply` refuses).
* **Cap:** 100 tag writes per run (hard ceiling; `--max-writes` can only lower
  it). Re-runs are no-ops: a tag already on the ticket is counted, not re-posted.
* **Lock:** `/var/lib/hydra/credit-status-writes.lock`, the same one
  `claim_executor` holds — both touch the claim tray. Held ⇒ the run exits 0 and
  writes nothing. The **applying** revert (`--revert … --apply`) takes that same
  lock for its whole run (ledger read, deletes, read-backs): a rollback that
  scanned a ledger while the timer was appending would remove what it saw, report
  `errors: []`, and leave the tags added afterwards live. Held ⇒ the revert
  **exits 2 and deletes nothing** — a rollback that did not run must not look
  like one that found nothing. A `--revert` DRY RUN takes no lock, so the
  pre-apply check stays runnable while a run is in flight.
* **The write revalidates the decision, not just the tag.** The scan happens
  once and the writes come later, so a human can close a ticket, retag it out of
  `action:profile-claim`, or change its Profile ID/email in between. Before each
  POST the drainer re-reads the ticket and skips the write if the status is no
  longer open, the action tag is gone, or the identity changed — it records a
  `stale-skip` row and counts it as `skipped as stale` in the digest.
  Every tag this drainer writes is a statement about CORE, and core moves too, so
  it re-reads the claims for that account **immediately before each write** and
  re-checks the statement. A batch-level read is not enough: a claim can be
  reverted between two writes in the same run, and the read would then still stamp
  the later ticket `complete`. The staleness window is therefore the POST itself.
  The check is on the claim(s) the decision RESTS ON, so an unrelated processed
  claim on another profile cannot vouch for this ticket:
  - `customer-outcome:complete` — the claim is still `processed`, or still
    `rejected` with a `claim_executor` audit row; a `processed` claim reverted
    back to `pending` is skipped.
  - `customer-outcome:verification-required` — the claim is still open with no
    identity proof submitted behind a recorded ask.
  - `drain:awaiting-user-submission` — the account still has NO claim: a claim
    filed between the scan and the write means the ticket is not unclaimed.
  This is not a full re-classification (the pending branch would cost a facts read
  and an account-gate call per claim); it re-checks exactly the fact the tag
  asserts. An unreadable revalidation stops the run — a failure is never
  permission to write.
* **Recheck budget.** A single-user claim read takes ~4s on node-8, so per-write
  revalidation costs real time. One run may spend `RECHECK_BUDGET_S` = 300s of it
  (`--recheck-budget`): when it is gone the run stops writing, says so in the
  digest, and the remaining decisions wait for the next tick. In practice that
  bounds a run at roughly 80 tagged tickets even though the write cap is 100.
* **Replica rows fail closed.** A claim row with the wrong column count, a
  non-numeric id, an unreadable timestamp, or a `verificationlinks` blob that is
  not a JSON object raises instead of being skipped. Skipping a row makes an
  account look like it never claimed (`drain:awaiting-user-submission`) and a
  malformed links blob looks like "no identity proof"
  (`customer-outcome:verification-required`); both would be tags asserting a fact
  the read never established.
* **Ledger:** `/var/lib/hydra/clickup-drain/profile-claim.jsonl`, one row before
  each network call (`result=pending`) plus the outcome and a `read-back` row
  (`stale-skip` rows record a decision that did not become a write).
  A corrupt line makes `--revert` refuse rather than skip it. `--revert` requires
  BOTH an `add-tag … http-2xx, tag_present_before:false` row **and** a following
  `read-back … verified` row for that ticket+tag: ClickUp can answer 200 and apply
  nothing, and a human may have added that tag afterwards, so a 200 alone is not
  proof we own it. A tag added and verified AGAIN after an earlier `--revert` is
  a fresh candidate again (the earlier `remove-tag` row does not shadow it), and
  so is a later add whose response was lost — the removal marker settles the add
  it removed, never a newer attempt on the same ticket+tag.
  Ownership is scoped to the LATEST attempt, not to the ticket+tag: a later
  `add-tag … tag_present_before:false` row is proof the tag was absent at that
  instant, so it retires any earlier `read-back … verified` row, and only that
  attempt's own verified read-back can re-establish ownership. Without this, a
  retry that ClickUp answered 200-without-applying left the OLD verified row
  standing, and a tag a human restored afterwards was deleted by `--revert` as
  ours.
  An add whose read-back said `missing` is reported as
  `unverified_adds_ignored`; an add with NO read-back row at all is not ignored
  (see the reconcile rule below).
  `--revert` appends its own `remove-tag` rows to THAT SAME ledger (never a
  sidecar): the next `--revert` decides what we still own by reading that one
  file, so a removal recorded elsewhere would leave the original add standing and
  a second revert would delete a tag a human had restored. A removal counts only
  once its own `remove-read-back … verified` row is there — a DELETE that answers
  2xx and leaves the tag raises, is reported in `errors`, and stays a candidate
  for the next run (`unverified_removals_ignored`).
  A tag that is **already gone** when the revert looks is a terminal fact too, so
  it is written as `remove-tag … already-absent` rather than returned silently:
  without that row the original `read-back … verified` add stayed the newest word
  on disk, and a second `--revert` deleted a tag a human had re-added in between.
* **A write with no answer is reconciled against ClickUp, never assumed.**
  `clickup_client` retries transport errors and then raises a bare
  `RuntimeError`; a POST whose responses were all lost may have applied the tag.
  The ledger records that row as `ambiguous:<Error>` (and a process death leaves
  the pre-call `pending` row), and `--revert` reads that ticket once before it
  calls the rollback complete: tag present = a candidate, absent = nothing to
  undo, unreadable = an entry in `errors` and exit 1.
  **A 2xx add with no `read-back` row is the same uncertainty**, not a settled
  one: ClickUp accepted the POST, then the process died or the read-back GET
  failed. Counting it as "ignored" let `--revert` report `candidates: 0`,
  `errors: []` with the tag live, so it is reconciled exactly like a lost
  response.
  **A 5xx is the same uncertainty, not a refusal.** ClickUp can fail AFTER it
  committed the write (a post-commit server error), so `http-500` is reconciled
  against the board too; only a 4xx or a 429 is treated as "refused before
  acting" and needs no read. The report's
  `ambiguous_reconciled` / `ambiguous_live` / `ambiguous_absent` counters say how
  many candidates only the live read could prove. The read also runs in the
  `--revert` DRY RUN (GET only) — a dry run that under-reports candidates is the
  same lie in a quieter voice.
* **Trays:** `/var/lib/hydra/clickup-drain/profile-claim/trays/`, mode 0600,
  never overwritten. Run one row first:
  `python3 scripts/credit-fable-execute.py <tray> --apply --limit 1`, then the
  whole tray. The executor's kill switch is a SET of paths, not one —
  `/etc/hydra/fable-trays.disabled` (current) and
  `/etc/hydra/fable-decider.disabled` (legacy, still honoured so a host rename or
  a rollback never silently re-enables the executor). Either one being present is
  why a tray can sit unexecuted, and the run names every path that is actually
  there rather than guessing at one.
* **Stop on the first surprise:** a non-2xx, a tag that does not read back, a
  tray that cannot be written. The remainder waits for the next tick.

## Retiring it

When the queue is empty (`0` in every bucket) disable the timer in the same PR
that removes the drainer:

```bash
systemctl disable --now clickup-drain-profile-claim.timer
```

Reverting the repo files alone leaves the installed timer running against a
script that may no longer exist.
