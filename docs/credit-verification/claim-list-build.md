# The claim list is built on a schedule

`credit-verify-outbound`'s claim families (`claim-proof-ask`, `claim-status`, paid and free) send
from one file, `/var/lib/hydra/credit-verify-outbound/claim-list.json`. The tick refuses the file
unless `signed_on` equals `/opt/hydra/.deployed-sha` (`list_signed_on_stale`), and the loader
refuses it past 30 h or without a recent `daily_check`. The file used to be built by hand from lane
tooling, so every deploy made it stale until somebody rebuilt it. It was last built 2026-11-07 and
refused on every tick until 2026-11-12: five days in which no claimant heard from us.

`scripts/claim-list-build.py` (rules in `scripts/credit_review/claim_list.py`) is that hand pipeline
as one run. Nothing in it is new policy: the audience rules are the ones of the signed batches.

## When it runs

| Trigger | When | Why |
|---|---|---|
| `claim-list-build.timer` | every 2 h at :20 (odd hours UTC) | 40 min ahead of the outbound tick (`0 */2`) |
| `claim-list-build.path` | `/opt/hydra/.deployed-sha` changed | a deploy gets a list signed on the new head within minutes |

Both start `claim-list-build.service`. All three are written by `scripts/install-aux-units.sh`.

## What one run does

1. Reads the deployed head, the daily code check's record
   (`/var/lib/claim-proof-check/last-run.json`) and the code secret. Any of them missing stops the
   run before the expensive reads.
2. Runs core's claim decider as a **dry run** over the whole pending queue
   (`kubectl exec deploy/core-backend-api -- node scripts/claim-review-decider.js --no-judge --limit 5000`).
   An applying, capped, cut-off or partial-scope run is refused.
3. Reads the pending claims (replica), the send ledger, the account holds and each profile.
4. Classifies: a proof ask for a person claim in band B/C with `request_proof` and a readable bound
   surface that was never asked; a status line for the rest. Held accounts, the decline tray and
   class A are never listed. Then one audience per user, the no-channel tray, the 7-day rule.
5. Adds each ask's proof code (core's `codeFor`, pinned to core's own vectors), `daily_check` and
   `signed_on`. A code that would differ from one already issued refuses the run.
6. Runs the deployed loader (`claim_proof_ask.load_list`) on the staged file. That is the sign-off.
7. Re-reads the deployed head. If a deploy landed mid-build it rebuilds on the new head.
8. Backs up the live list, copies to a temp file on the same filesystem, verifies the sha256,
   replaces with one rename, verifies again.

It sends nothing. The claim families send from the list through their own checks and gate.

## A read that does not answer is a failed run

Exit 1, nothing installed, the live list byte-for-byte what it was, and `OnFailure` pages
`#clio_devops`. The reason code is in the journal line and in
`/var/lib/hydra/claim-list-build/last-run.json`:

`decider_failed` `decider_capped` `decider_cut_off` `decider_incomplete` `decider_not_dry_run`
`decider_wrote` `decider_scope` `decider_unreadable` `decider_empty` `decider_no_header`
`facts_unreadable` `holds_unreadable` `holds_stale` `ledger_unreadable` `catalog_unreadable`
`catalog_too_slow` `daily_check_unreadable` `daily_check_stale` `code_secret_unreadable`
`deployed_head_unreadable` `code_changed` `loader_refused` `empty_list` `head_moved`
`mixed_audience` `backup_failed` `install_failed` `builder_error`

Exit 0 builds nothing when `/etc/hydra/claim-list-build.disabled` exists (`held`) or another build
holds the lock (`busy`); both are recorded in `last-run.json` the same way.

An unreadable or stale hold file is never "nobody is held", an unreadable ledger is never "nobody was asked".
A valid hold file that lists nobody is healthy: the journal line carries `holds 0 (file valid, no account held)`.

## Operating it

```bash
journalctl -u claim-list-build.service -n 20          # CLAIM LIST BUILD: INSTALLED | FAILED ...
cat /var/lib/hydra/claim-list-build/last-run.json     # the last outcome, both hashes
tail -n 5 /var/lib/hydra/claim-list-build/builds.jsonl
python3 /opt/hydra/scripts/claim-list-build.py --dry-run   # build and sign, install nothing
```

- **Stop**: `touch /etc/hydra/claim-list-build.disabled` (exit 0, nothing built). The live list then
  ages out and the tick skips the claim families, loudly.
- **Undo an install**: every replaced list is kept in `/var/lib/hydra/claim-list-build/prev/`
  (`<stamp>-claim-list.<sha12>.json`, last 48). Copy one back over the live path. A list signed on
  an older head is refused by the tick, so restoring one stops claim sends rather than repeating them.
- State is under `/var/lib/hydra/claim-list-build`, not `/opt/hydra`, which the deploy overwrites.

Tests: `scripts/tests/test_claim_list.py`, `scripts/tests/test_claim_audience.py`,
`scripts/tests/install-aux-units-claim-list-build.bats`.
