# Evidence 06 - the outbound sender stopped itself, and was restarted by hand from a login session

Source: `ssh root@40.160.32.80` (ovh-node-8), 2026-11-12 16:46-16:55Z, read-only. File names, sizes
and times were listed; no kill file's contents and no message body were read. This lane changed
nothing on the host and sent no signal.

This was found by accident: the open-file sampler recorded a credit job holding the decision
ledger from a login session instead of from a scheduler.

## Read this first (added 17:04Z, after checking the other lanes' records)

The first version of this file left the cause of the stop and the reason for the restart as
unknown. Both were on record in another lane, which this lane had not read. With that read:

- **The cause was already diagnosed.** Lane `hydra-tick-budget-fix-v1` traced the 14:28Z stop (and
  the same error at 10:35Z and 12:27Z) to the daily-cap read opening the ledger through the
  write-capable `verify_ledger.connect`, whose migration step takes a write lock. Its fix switches
  those reads to `connect_ro`: https://github.com/Muso-AI/hydra/pull/1917, on `main` as `fa1c3072c`
  at 16:21:02Z.
- **The fix was being deployed when the sender was restarted.** Deploy run `43257759792` (the same
  run that restarted both gateways, evidence 04) was dispatched at 16:21:28Z on `fa1c3072c`,
  wrote `/opt/hydra/.deployed-sha` at 16:35:32Z and finished `success` at 16:38:16Z. The deployed
  `scripts/credit_review/uvn_status.py` contains `connect_ro`.
- **The step that stopped it at 14:28Z has now passed.** At 14:28:32Z the `uvn-status-free judge
  SHADOW` line and the `AUTO-KILL` line carry the same second. In this run the same judge line is
  stamped 17:02:55Z; at 17:03:44Z there is no `AUTO-KILL` line, no kill file, and the sender is
  still running. Lines stamped 16:35Z or later matching `readonly|AUTO-KILL|FAILED|Traceback`: 0
  (bounded to timestamped lines this time). Whether this tick goes on to send was not yet visible.

So this was a restart after a fix, not a stop being overridden with the fault still in place.
What is still open is narrower, and listed under "What was not established".

## What ran

`/opt/hydra/scripts/credit-verify-outbound.sh`, in `session-861539.scope` under `user.slice`.

- The session was opened at 16:33:11Z by `sshd`, public key, from `10.0.0.1`. `loginctl` reports
  `Service=sshd`, `Remote=yes`, `State=closing`: the SSH connection has ended and the script was
  left running with parent pid 1.
- It was still running at 16:55:16Z (22 minutes in). Children seen: `credit_review/reply_due_scan.py`,
  `credit-review.py uvn-status --segment paid`, then `--segment free`, `credit_review/receipts.py`,
  `credit_review/comm_state.py check`, `kubectl`.
- Its output directory is `/root/h2-runs/sched/20261112T1633Z`.
- This lane's own reads arrive from `8.20.19.174`, a different address.

The same script has a scheduled entry: `/etc/cron.d/credit-verify-outbound`, `0 */2 * * *`.

## Why it was started by hand

From `/var/log/credit-verify-outbound.log`:

| time (UTC) | line |
|---|---|
| 14:28:32 | `AUTO-KILL: uvn-status-free: cap source unreadable (ERR OperationalError attempt to write a readonly database) (wrote /etc/hydra/credit-verify-outbound.disabled)` |
| 14:28:32 | `credit families: FAILED and the kill file is present (auto-kill); nothing more runs` |
| 16:00:01 | `kill file ... present; nothing runs` (the scheduled tick) |
| 16:30:43 | `kill file ... present; nothing runs` (an off-schedule attempt) |
| 16:35:18 | `tick start: live=1 paid_live=1 ...` |
| 16:52:05 | `uvn-status-paid page: entries from 585 this tick; next tick starts at 805` |
| 16:53:56 | `r1-paid page: entries from 574 this tick; next tick starts at 0` |

And from the filesystem:

- `/etc/hydra` (the directory) was last modified at **16:33:11.299Z**.
- `/var/lib/hydra/credit-verify-outbound/tick.lock` was written at **16:33:11.409Z**, 0.11 s later.
- At 16:54:41Z and 16:55:16Z neither `/etc/hydra/credit-verify-outbound.disabled` nor
  `/var/lib/hydra/credit-verify-outbound/credit-verify-outbound.disabled` exists.
- Earlier lifts left a copy of the kill file on the host, in two different ways: a rename inside
  `/etc/hydra` (`...disabled.lifted-20261107T1005Z`; `...lifted-20261112T1125Z`, whose 10:35:57Z
  timestamp is when that kill file was written, the rename keeps it), and a backup at
  `/var/backups/credit-verify-outbound.disabled.20261112T1320Z` for the 12:27Z one. The 14:28Z kill
  file has neither: no later `lifted-*` in `/etc/hydra`, no later copy in `/var/backups`.

So the sender stopped itself at 14:28Z on a store error, the kill file was removed at 16:33:11Z
without a copy kept on the host, and the sender was started from the same SSH session in the same
second. That is 2 min 21 s before the deploy wrote its sha and 5 min before the deploy run
finished. It has been running live since 16:35:18Z.

This also confirms evidence 02, which listed `credit-verify-outbound.disabled` as present at
16:03Z. It was.

## What was not established

- Who opened the session from `10.0.0.1`. The fix lane's own status, written at 16:34:46Z, says it
  is standing by for the deploy and does not claim the lift; its 14:28Z note says it left the kill
  file in place on purpose until the fix deployed. No status file in the firstmate state directory
  modified since 14:00Z records the 16:33Z lift.
- Whether the 16:33Z start ran the new code. The sha file is written at the end of a deploy and the
  gateways had already been restarted at 16:23Z and 16:28Z, so the files were very likely in place;
  the file sync time itself was not read.
- Whether the fix covers every read. The fix lane reports 2 of 17 ledger opens changed in its first
  commit and "the two remaining provable reads" in a second. A reviewer lane (`pr-review-fable-r8`)
  recorded a NO-GO on the merged change: `connect_ro` raises on a ledger that is behind the schema,
  and two callers do not catch it, so the tick would abort before a send. Neither claim was checked
  here. As described, that failure stops the tick; it does not send anything wrong.
- Whether the mechanism that removed the file was the script itself or a separate command.
- Off-schedule run directories also exist for 02:26Z and 02:29Z today. What started those was not
  looked at.

Timing rules this lane out as the cause of the 14:28Z error: it was idle from the previous day
until 16:02Z, and its first sqlite read on 11-12 was at 16:03Z.

## What this means for the map

1. **There is a fourth way work starts on node-8**: a command run by hand or by another agent over
   SSH and left running in a login session. It belongs to no unit, appears in none of the three
   scheduler inventories (evidence 03), and nothing restarts or reaps it. At 16:46Z the host had 28
   root login sessions.
2. **The process sampler in this lane does not see it.** It samples `system.slice` only. CPU used by
   session-started jobs is therefore missing from the per-command CPU figures; the open-file
   sampler, which is not limited by slice, does record them.
3. **The kill file worked as a switch and was also bypassed as one.** The scheduled tick honoured
   it twice. Removing a file is all it took to undo it, and the only trace is a directory timestamp.
   Any plan that moves a job off this host has to carry this switch with it, and this is what the
   switch currently amounts to.
