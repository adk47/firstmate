# al-node8-units-d10-u2 notes (node-8, after deploy 10 = 5b1f495a1)

All reads on node-8 were read-only (`ssh -J ubuntu@135.148.169.37 root@10.0.0.8`). Nothing was sent, restarted or written.

## 1. verification-standing.service FAILED 22:10Z, exit 3

- Script `scripts/verification-standing.py --save /var/lib/hydra/verification-standing`; the reason is in
  `/var/lib/hydra/verification-standing/latest.txt` (and `latest.json`), the unit's stdout is `null`.
- The 22:10Z page: `unmeasured, not zero - sent_this_tick: tick 20261116T2200Z under /root/h2-runs/sched recorded no apply`.
  (`held_evidence_unbounded` is unmeasured too, but it is in `NO_WRITER_YET`, so it never fails the unit.)
- Why: `read_tick` takes the NEWEST tick directory under `/root/h2-runs/sched`; the outbound tick started 22:00Z and its
  first `*-apply.json` (`claim-status-paid-apply.json`) landed at 22:12:45Z, 2m45s after the 22:10Z standing run. A tick
  with no apply yet (in flight, or a tick that applies nothing, e.g. 20261116T1900Z which wrote one check and no apply)
  is `unmeasured` by design (doc §`sent_this_tick`), and a written unmeasured cell exits 3.
- Not new with deploy 10: the unit has existed since #2041 (432a528fd, 08:03Z today, first run 10:40Z). Runs today:
  FAIL 10:40 11:10 12:10 13:10 13:40 19:10 19:40 20:10 22:10; ok otherwise (9 of 24). 19:10-20:10 failed before deploy
  10 went live (21:46Z). `git log 9d01302c5..5b1f495a1` = 5 commits (#2111 #2112 #2131 #2132 #2136), none touches
  `verification-standing.py`, its test, or the sender's tick-dir layout.
- Fix owner: the verification-standing page (#2041) - `read_tick` should read the newest tick that has finished or
  recorded an apply (or treat an in-flight tick as "not yet"), not fail the unit on a race with the hourly sender.
  Not a deploy-10 revert, so no PR from this lane for it.

## 2. credit-thread-reply-tick.service FAILED since 2026-11-11 22:08:05Z

- Unit + timer were written by `/root/units2.sh` (2026-11-10 21:53Z); ExecStart `/usr/bin/python3 /root/thread_reply.py 200 --send`.
  The timer file exists (`OnUnitActiveSec=30min`) but is `disabled` + `inactive`: `/root/today1.sh` (2026-11-11 22:27Z,
  "== 1. disable dangerous senders ==") stopped and disabled `credit-thread-reply-tick.timer` together with
  `credit-notify-tick` and `sender-reminder`. So "no timer" is a deliberate stop, 19 minutes after its last run.
- Why the last run failed: line 4 `TOK = open("/tmp/.ictk2").read()` - a hand-placed Intercom token in /tmp;
  `/tmp/.ictk2` does not exist now; the run used 36 ms CPU and exit 1 (an import-time FileNotFoundError fits; the
  journal for that run has rotated, so the traceback itself is not readable).
- What it sent (verify ledger, campaign `thread-loop-close`): 555 `sent` rows, 555 conversations,
  2026-11-10 17:28Z .. 2026-11-11 17:31Z (405 in the first hour).
- What the script does: walks EVERY open Intercom conversation, and replies to any whose last part is a user's, with one
  fixed body: "Your verification request is still open ... Nothing further is needed from you right now ... will email
  you when yours has been reviewed". No topic check, no account check, no copy gate, no hold for billing/legal/erasure,
  no assignment check, raw token, ledger write by bare `sqlite3.connect`.
- Read-only count (caroline-monitor facts, `/var/lib/hydra/caroline-monitor/monitor.sqlite`, reading 21:36Z, using
  `caroline_monitor.backlog.waiting_since`, robot mail excluded): 842 open threads wait on us in all; 18 started waiting
  on/after 2026-11-11 00:00Z, 17 after the unit died (5 of them over 24 h). Shapes of the 17: proof_sent 5,
  request_status 2, merge_split 2, claim_start_problem 2, other 2, app_bug 1, billing_question 1, claim_conflict 1,
  credit_wrong 1. (`support-backlog.json`: waiting_on_us 830 over 24 h, by wait under_2d 0, 2d-7d 6, 7d-30d 3,
  30d-90d 47, over_90d 774.)
- Why codifying it as-is is wrong (evidence):
  - its body matches `NOTHING_NEEDED_RE` in `scripts/outbound_copy/gate.py:159` (captain bar 2026-10-30), so through the
    gate it can never send in any mode; and "will email you when yours has been reviewed" is an unbacked promise.
  - it tells an app_bug / merge_split / billing thread "your verification request is still open".
  - the coded owner of exactly this population exists: `scripts/intercom-backlog/drain.py` (fixed gate-reviewed lines,
    owner/separate/held lists, hand-back to Caroline's live turn; `docs/support/backlog-drain.md`), run by hand, no
    timer. A second customer-last sender is what AGENTS.md says not to grow.

## 3. `Unknown agent id "support"` on openclaw main

- Caller: `hydra-peer-labels.timer` (every 5 min) -> `hydra-peer-labels.service` -> `scripts/provision-peer-labels.sh main`
  (written by `scripts/install-aux-units.sh`). Phase 1 asks the gateway `sessions.create {"key":"agent:support:main",
  "agentId":"support"}` for every peer in the main map; main's gateway journal shows
  `sessions.create ... errorCode=INVALID_REQUEST errorMessage=Unknown agent id "support"` at 22:21:37, 22:26:38, 22:31:37Z.
- Caroline's support agent is NOT missing: it is on edge (`/root/.openclaw-edge/openclaw.json` agents.list = `support`;
  the same tick logs `provision-peer-labels[edge]: bootstrapped agent:support:main`). main's agents.list (live and
  repo `openclaw-main.json`) = clio ceo cmo cto qa finance operations devops scout. #352 (72eeff11b, 2026-05-27)
  removed support from main's config but left `[support]="@CS"` in the script's main map (added #171, 2026-04-24).
  The error is as old as #352; the journal only reaches back to 2026-11-14 16:50Z, hence "seen since".
- Fix (this PR): drop `support` from main's peer map, and skip any peer the profile's own `agents.list` does not name
  (an unreadable list keeps the whole map). Tests in `scripts/tests/provision-peer-labels.bats`: main's map is a subset
  of `openclaw-main.json` agents; a peer not in agents.list gets no sessions.create; unreadable list keeps all 9.
  Mutations: re-adding `[support]` fails test 7 (and 9); disabling the `unset` fails test 8.
- Revert: `git revert <merge sha>`; the 5-min tick then sends main the support create again (harmless error line).
- Side finding, not fixed here (openclaw 2026.8 sessions are SQLite): `agents/<id>/sessions/sessions.json` no longer
  exists on main, so every tick logs `bootstrapped agent:<id>:main` for all 9 agents (a sessions.create per agent per
  5 min) and then `done: 0 patched, 10 skipped` - the label writer is a no-op on 2026.8. Whether a repeated
  sessions.create on an existing key resets anything was not measured. Owner: openclaw-expert / gateway lane.
