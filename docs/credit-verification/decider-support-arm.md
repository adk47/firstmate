# The credit decider's SUPPORT-ONLY writer

Fable d2 ruling `[key=decider-support-arm]` (2026-11-04, issued through
`verif-closeout-fable-v2`): re-enable the credit decider (`credit-review.py decide`) as a
**writer of the SUPPORT arm only**. Support moves a held credit `unverified` →
`user_verification_needed` (core's Knock message asks the user for proof). The **approve arm is
hard-off in code**: an approval is still *decided* and *recorded*, and it is never *written*.

This page is the contract. Every condition below names its code and the test that fails when the
code is removed — a condition without such a test was not shipped.

## Why support only

The decider's approve arm writes `approved` on evidence alone. The support arm writes nothing
except "we need proof from you", which is reversible by the user sending documents and is what
the 537 waiting `credit/no_decision` users need tonight (235 paid). Approve stays off until the
evidence bar (`assert_never_lower`, `credit_anchor_records`, the DSP anchor path) is live on
core — see `docs/credit-verification/credit-trust-llm.md` and the close-out reports in
`data/credit-refresh-t01b/closeout-372/`.

## The six conditions

### 1. Support-only, enforced in code (the kill file is defence in depth)

- `scripts/credit_review/decide.py` → `Policy.approve_arm` (default **False**, a JSON boolean;
  `bool("false")` is True, so a string is a `ValueError`).
- `approve_arm_off(policy)` returns why the arm may not write. It refuses when the policy does not
  say `true`, and refuses an **unreadable** switch (cannot prove the switch absent ⇒ arm is off).
  When the policy *is* armed, `/etc/hydra/credit-trust-decide-approve.disabled` still refuses
  (env `CREDIT_TRUST_DECIDE_APPROVE_DISABLED`).
- The transformation runs before the shadow/judge return, and **only in `apply` mode**: the run
  books every withheld approval as `held:approve_arm_disabled`, sets `held_approve_arm`, and adds
  `APPROVE ARM OFF (…)` to the run note. Shadow/judge keep counting *verdicts* and say plainly
  that none of them would be written.
- **A tripwire sits at the WRITE boundary** (`write_ids()`), not only at the caller, so a future
  caller cannot re-open the arm by accident; the run books the rows `held:approve_arm_disabled`,
  appends a `write boundary` line to `write_errors`, and lets the support arm finish.
- Unchanged: `KILL_SWITCH` (`credit-trust-decide.disabled`) stops both arms, and
  `PROVISIONAL_PAID_SWITCH` keeps gating `provisional_paid` approvals if the arm is ever armed.

Tests (`scripts/tests/test_credit_trust_decide.py::SupportOnlyArm`): verdict recorded with no PUT,
support still writes in the same run, the code default is off, a string is not a boolean, the
switch blocks an armed policy, **armed + unswitched still approves** (the control), an unreadable
switch refuses, and the write-boundary tripwire refuses when the caller check is bypassed.

### 2. One named sender for the Knock ask

The support write's note comes from core, so no hydra sender posts it — but the ask must be
**ledgered**, or the tick's own campaigns (`uvn-status`, `gap-ask`, …) cannot see that the user
was asked today and would mail the same person the same day.

- `scripts/credit_review/verify_ledger.py` → campaign `decider-support` (in `CAMPAIGNS` **and**
  `ASK_CAMPAIGNS`, so the shared one-ask-ever / per-day locks see it), written by
  `record_external_ask()`. It is deliberately **not** `uvn-status`: `prior_uvn_ask()` stays False
  (the decider's in-app note is a different flare than the uvn-status email ask).
- `decide.ledger_asks()` writes ONE row per **asked user** (all their landed requests),
  `approved_by = "credit-trust-decide"` (`decide.ASK_SENDER`), `approval_ref =
  decider-support:<run_id>`, `status = sent`, after the PUT **landed** — never before (a phantom
  ask would block the user's real one). Deferrals/refusals are never ledgered as asks.
- A ledger failure is booked on the run (`write_errors`, `ASK LEDGER INCOMPLETE` in the note) and
  in `state['support-writer:ask-ledger-error:<run_id>:<user_id>']` — one row per affected USER, so
  N stranded users cannot overwrite each other — which the paging alert reads.
- **The gap is discharged, not permanent.** `run_readback()` is the reconciliation, so a read-back
  that records `ok: true` also deletes that run's gap rows (`cleared_gaps` in the read-back doc).
  The alert additionally skips any gap whose run has an `ok: true` read-back, which covers rows
  written before that fix. A gap whose read-back did **not** confirm every ask keeps paging: an ask
  core does not show is still a real gap.

Coordinated with `verify-ask-wiring-h2`: same table, same locks, same per-day cap.

### 3. Caps in USERS

- **Per run**: `Policy.max_ask_users_per_run` (policy `max_ask_users_per_run`, default 100),
  applied in `filter_support()` on the **paid-first** decision order (a user's whole batch stays
  together), and re-checked across `BATCH` chunks at the write boundary through
  `cap_at_write(..., run_cap, admitted_run)` — a cap counted per chunk would admit `BATCH ×` users.
- **Per day**: `max_ask_users_per_day` (400 in the deployed policy), re-read under the write lock.
- **One move per user per 24 h**: `cap_at_write()` refuses a row whose user another run asked
  inside `SUPPORT_WINDOW` (`deferred:per_user_window`), and `filter_support()` never re-asks a
  request or a user inside the window.

Deferrals are visible: `deferred_run_cap` / `deferred_ask_cap` / `deferred_window` are in the run
line.

### 4. A paging alert ships in the same PR

`scripts/credit-decider-support-watch.py`, scheduled every 30 min by
`/etc/cron.d/credit-decider-support-watch` (installed by `scripts/install-aux-units.sh`), pages
`#clio_devops` with real `<@UID>` mentions:

| key | fires when |
| --- | --- |
| `approve_written` | an `approved` outcome exists on an `apply` run while the arm is off — the one thing this scope exists to prevent |
| `ask_ledger_gap` | a landed ask was not ledgered (double-ask risk) |
| `support_write_error` | a support PUT errored in the last 24 h |
| `candidates_but_silent` | the **support writer** is on (writer kill file absent **and** an enabled `--mode apply` cron exists) **and** candidates existed in the window with zero asks sent |
| `readback_owed` | an apply run has owed its read-back past the grace window (the next apply is refused) |
| `readback_failed` | a read-back was recorded but did **not** confirm every row (`ok` is not `true`) and is past the grace window — the gate is still closed, so this is a wedge, not a clear |

Three details that are easy to get wrong, and are why each has its own test:

- **The silence branch is keyed on the SUPPORT arm, never the approve arm.** `approve_arm: false`
  is what this PR ships, so gating silence on it made the alert unreachable in exactly the
  configuration it shipped in. The support arm's authorization is the writer kill file plus a
  scheduled `--mode apply`; an unscheduled or killed arm is silent by design and never pages.
- **A page is stamped in the dedupe state only after delivery succeeded.** `slack_notify_critical`'s
  exit code is checked, so a Slack outage does not silence the only alert for the condition for the
  whole dedupe window — an undelivered page is retried on the next tick and the run still exits 1.
- **A failed read-back keeps the wedge visible.** `ok: false` (or an unreadable record) means
  `pending_readback` still refuses the next apply, so the watchdog pages `readback_failed` past the
  grace window instead of skipping the run because a read-back key exists.

Detect-and-page only: it never lifts a kill file and never writes a credit. Exit 0 clean, 1 paged
(including a page that could not be delivered), **2 cannot measure** (a missing/unreadable ledger is
never "clean"). Deduped per key (6 h).

### 5. A read-back after the first apply run, before the second

- Every apply run that landed asks is recorded (`state['support-writer:apply:<run_id>']`).
- `credit-review.py decide --mode apply` **refuses with exit 3** while any such run has no
  confirmed read-back.
- `credit-review.py decide-readback --run <id>` reads core back for that run's asks through the
  read-only Trino verifier and records `{checked, confirmed, missing, ok}`. **Only `ok: true`
  clears the gate**: a partial answer or an unreadable read-back is recorded and keeps the arm
  wedged (visible, and the alert pages).

### 6. Everything else per d2's ruling

- The approve *verdict* still lands in `decisions` before any write — stage 2 and every reader
  work from that table, and the support-only scope must not blind them.
- Ledger before PUT (unchanged): the decision row precedes the conditional-status call.
- The deployed `policies/credit-trust-decide.json` carries `approve_arm: false` — the shipped
  policy, not just a runtime file, says the arm is off.

## Arming (an ops step, deliberately NOT in this PR)

Nothing here writes anything until **all five** steps are done. Until then the arm is inert and the
silence alert stays quiet (it only pages when the arm is armed *and* scheduled).

1. Deploy outside a tick window (the judge cron runs `*/15`; the writer cron must not fire mid-deploy).
2. Create `/etc/hydra/credit-trust-decide-approve.disabled` (defence in depth) and keep
   `/etc/hydra/credit-trust-decide-provisional-paid.disabled` as ruled.
3. Remove `/etc/hydra/credit-trust-decide.disabled` — the writer kill file.
4. **Flip the registry**: `policies/credit-approval-automation.json` → `automations.credit-trust-decide`
   is `approved: false` today, and `muso-admin-api.sh` refuses every apply write while it is. Setting
   `approved: true` + `approved_by` + `approval_ref` **is** the captain's recorded approval for the
   support-only writer (that is what the registry exists for) — its own PR, citing d2 `[key=decider-support-arm]`.
   Without it `run()` falls back to shadow (`registry_approved()`), so nothing is sent.
5. Schedule `credit-review.py decide --mode apply` (a cron change, its own review).
6. After the first run, read it back before the second:
   `python3 scripts/credit-review.py decide-readback --run <run_id>`.

Turning the APPROVE arm on later is a policy PR (`approve_arm: true`) that still needs the switch
removed — and its own ruling.

## Evidence measured on node-8 before this PR

- The alert has teeth: `--since 2026-10-05` finds **654** apply-mode approvals the decider wrote while
  the arm was legitimately armed (the newest `2026-10-26T23:17:06Z`, i.e. before the 2026-10-30
  judge-only cutover). Those are history, not violations, which is why `SUPPORT_ONLY_SINCE`
  (2026-11-05) floors the finding — otherwise the deploy would page on the backlog every 6 h and
  train people to ignore the one signal that matters. `--since` stays available for audits.
- Default window on prod today: **clean** (no approvals since the scope began).
- `apply_cron_scheduled()` is **False** on prod (only the judge job exists), so the silence arm is
  quiet for the right reason.
- The deployed policy has no `approve_arm` key and the shipped one says `false`; both read as OFF
  (an unreadable/absent key is a refusal, never an arm).

## Rollback

Write `/etc/hydra/credit-trust-decide.disabled`: both arms stop (judge keeps running). Nothing in
this PR has to be reverted for that to work, and no credit is un-approved by stopping.
