# Intercom identity reconcile + fraud lens (Fable ruling-intercom-external-id-1026)

Captain 2026-10-26 ~00:40Z: "fix all the issues now!" / "we must be monitoring and validating
requests with a fraud lens". The paid wave of 10-26 reached 76 of 437 paid users. About 138 of the
rest were refused by Caroline's gate because the Intercom user for their email carries an empty
external_id, or one that does not name their Muso account. Fable ruled: **keep the gate, fix the data**
(Ruling A), and **narrow the big-track single-signal messaging hold** (Ruling B). Code:
`scripts/credit_review/intercom_reconcile.py`, `scripts/credit_review/fraud_lens.py`. The module
docstrings carry the full rules.

## Ruling A: `credit-review.py intercom-reconcile`

One-time task, not a cron. Never messages anyone. Kill switch:
`/etc/hydra/intercom-identity-reconcile.disabled`.

| class | Intercom user(s) for the account email | decision |
|---|---|---|
| A1 | external_id empty | `fix` if every write condition holds, else `refuse_cs` |
| A2 | external_id is an orphan (no Muso account's professional id / Auth0 subject / users.id) | `fix` if every write condition holds, else it becomes A3 |
| A3 | external_id (or any contact with this email) names another Muso account | `refuse_cs`: no write, no message, listed with both account ids |
| A4 | 2+ users, none matching | A1/A2 per contact; exactly one can become the match: `fix`, else `refuse_cs` |
| A5 | Intercom answered `action_forbidden` | `hold_cs` (no email from this job; the ruling left email-vs-cs to the owner) |
| NONE / OK | no Intercom user / already matches | reported only |

**Write conditions** apply to every write (A1, A2, A4), all must hold:
- the account email is confirmed;
- the account is at least 30 days old;
- no other Muso account holds the email;
- no admin create or email change ever gave the email to another account. Source: `action_log`, which only starts 2026-09-01; core keeps no older email history;
- no Intercom contact with the email names another account;
- the account is paid;
- the professional id is on no other Intercom contact;
- the fraud lens does not hold the user. If it does, the row is `fraud_hold`.

```
set -a; . /etc/openclaw/main.env; set +a          # MUSOAI_INTERCOM_TOKEN
cd /opt/hydra
python3 scripts/credit-review.py intercom-reconcile --segment paid                    # dry run (default)
#   -> /var/lib/hydra/credit-review/intercom-reconcile/irc-dry-<ts>-<hex>.{json,md}, ...-cs.json
python3 scripts/credit-review.py intercom-reconcile --segment paid --mode apply \
    --approved /var/lib/hydra/credit-review/intercom-reconcile/irc-dry-<...>.json [--classes A2]
python3 scripts/credit-review.py intercom-reconcile --revert irc-<ts>-<hex>           # dry: what would be restored
python3 scripts/credit-review.py intercom-reconcile --revert irc-<ts>-<hex> --mode apply
```

- **Dry run** reads only. The ledger is opened read-only; Intercom and the replica are only searched.
  The `.md` file is the A1-A5 table to post before any write. The `-cs.json` file is the
  A3 / refused-A4 / A5 list for cs-systemic-issues-lane-c1: account ids, contact id, why. Nothing
  here ever carries an email.
- **Apply** writes only rows that were `fix` in the approved dry-run file and are still `fix` now, for
  the same contact and old id. For each one:
  1. re-read the contact;
  2. write the `intercom_identity_fix` ledger row (old and new id, class, run id, `pending`);
  3. `PUT /contacts/{id}`;
  4. re-read to confirm (`applied` / `unverified` / `failed`).

  The first apply run ever writes at most 50; later runs are capped by `--max-users`. A confirmed
  fix lifts that account's live identity refusal hold (`verify_refusal_holds.next_recheck_at` ->
  now, recorded on the ledger row). The strike count and any cs flag stay. No other hold is touched.
- **Revert** re-reads each contact, writes `reverting`, puts the old id back, re-reads, and restores
  the lifted holds that nothing has touched since. A row a crashed revert left `reverting` is picked up again by the next revert. A contact whose
  external_id, email or role changed since the fix is `revert_refused` and is never overwritten. The
  fix row keeps a sha256 of the contact's email and role, never the email itself. **A1 caveat:** the old value is empty, and Intercom does not document clearing an
  external_id. The revert tries `null`, and if Intercom keeps the id the row is `revert_failed` for a human.
- uvn-status refusals are terminal in the verify ledger (only the status notes have the 7-day hold).
  A fixed account whose only refusal was a uvn-status one is NOT re-opened by this job.

## Ruling B: the fraud lens (`fraud_lens.py`)

- **Held** (never messaged, never closed, re-checked every run), when any of these is true:
  - the user, their email, or a profile on an open request is on `policies/fraud-watchlist.json`
    (`credit_review/watchlist.py`);
  - the user is in `policies/fraud-lens-holds.json`, the named a1 / s1 / brief accounts. This file
    is messaging only and does not affect approvals;
  - velocity is above the s1 band over 90 days: more than 300 rows, or more than 10 rows at
    popularity >= 70, on one profile in one UTC day;
  - the user has **>= 10** open big-track single-signal rows: popularity >= 60 with
    `review_big_track_without_trusted_credit` / `review_big_track_weak_footprint`, or a lone
    `shortcut_source`.
- **Ask-only**: users with 1 to 9 such rows. `credit-review.py uvn-status` gives them only the
  `uvn-status` document ask, never `status-doc-received` (Copy A) or `status-team-review` (Copy B0).
- The uvn-status runner loads the watchlist and the holds file at start. If either is missing or
  malformed, it sends nothing.
- `credit-review.py fraud-lens --out DIR` builds the paid never-contacted population and writes
  `never.txt`, `clean.txt`, `ask-only.txt`, `fraud-held.json` and `lens-summary.json`. It replaces
  paid-wave-runner-p1's scratch pre-filter. Put the `ask-only.txt` users on the uvn-status list only.
- Gap: an ask-only user whose requests are not `user_verification_needed` in core is not reachable by
  the uvn-status ask, whose replica check needs UVN rows. The runner reports them as `ask_only` on
  the status-note campaigns and sends them nothing.
