# Evidence 03 - the three schedulers and what each runs (read-only)

Source: `ssh root@40.160.32.80` (ovh-node-8), 2026-11-12 16:06-16:20Z. Nothing was written on the host.
Gateway cron data comes from `cron_jobs` and `cron_run_receipts` in each profile's
`state/openclaw.sqlite`, opened `mode=ro`. Secret-shaped values in commands are masked.

## Work on node-8 is started by three unrelated schedulers

| scheduler | where it is defined | what it runs under | enabled entries |
|---|---|---|---|
| gateway cron, main profile | `/root/.openclaw-main/state/openclaw.sqlite` (repo: `cron-jobs.json`) | children of `openclaw-gateway-main.service` | 37 recurring (22 command, 14 agent turn, 1 heartbeat), plus one-shot jobs |
| gateway cron, edge profile | `/root/.openclaw-edge/state/openclaw.sqlite` | children of `openclaw-gateway-edge.service` | 2 (1 heartbeat, 1 agent turn) |
| host cron | root crontab + `/etc/cron.d` | children of `cron.service` | 8 crontab lines + 51 `/etc/cron.d` lines |
| systemd timers | `/etc/systemd/system/*.timer` | one transient service cgroup each | 71 timers (52 run something under `/opt/hydra`) |

Consequence for the map: "a service on node-8" is not one list. The credit-verification path alone
is started from all three (for example `credit-review.py decide` from the main gateway,
`credit-verify-outbound.sh` and the verification-steward ticks from host cron, `request-comms` and
`credit-precedent` from systemd timers).

## Gateway cron: recurring jobs

Wall time is `finished_at_ms - started_at_ms` from the run receipts. **It is elapsed time, not CPU**:
a job waiting on an API or a model call accrues wall time while using almost no processor.
Per-command CPU is measured separately in evidence 04.

The gateway keeps only about the last 64 receipts per job, so the window differs per job.
`window h` is the age of the oldest receipt for jobs at that cap, and 168 for the rest.
`wall h/day` is total wall time divided by that window.

| profile | job | on | agent | kind | schedule | receipts | window h | ok | error | other | p50 s | p95 s | max s | wall h/day | payload |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| main | credit-trust-decide-15m | yes | operations | command | `*/15 * * * *` | 65 | 16 | 61 | 3 | 1 | 255 | 287 | 305 | 6.56 | `python3 scripts/credit-review.py decide --mode judge` |
| main | credit-verify-proof-file | yes | operations | command | `15 * * * *` | 65 | 67 | 47 | 17 | 1 | 0 | 3000 | 3002 | 5.45 | `python3 scripts/credit-proof.py file-recent --apply --max-fetches 60` |
| main | credit-dsp-verify-d5b | yes | operations | command | `35 * * * *` | 64 | 64 | 55 | 9 | 0 | 0 | 1464 | 1546 | 2.20 | `python3 scripts/credit-dsp-verify.py d5b` |
| main | intercom-backlog-count-2h | yes | operations | command | `50 */2 * * *` | 64 | 127 | 64 | 0 | 0 | 367 | 420 | 428 | 1.19 | `python3 scripts/intercom-backlog/count.py` |
| main | credit-approval-auditor-hourly | yes | operations | command | `45 * * * *` | 64 | 64 | 64 | 0 | 0 | 97 | 524 | 988 | 1.05 | `python3 scripts/credit-review.py audit --window-min 90 --sample-rate 0.10 --budg` |
| main | credit-doc-verify | yes | operations | command | `50 * * * *` | 64 | 63 | 64 | 0 | 0 | 0 | 503 | 695 | 0.91 | `python3 scripts/credit-doc-verify.py run --max-docs 40 --workers 4` |
| main | credit-review-shadow-4h | yes | operations | command | `15 */4 * * *` | 43 | 168 | 42 | 0 | 1 | 423 | 900 | 1279 | 0.77 | `python3 scripts/credit-review.py review --phase shadow --limit 20 --sample-appro` |
| main | credit-verify-proof-stage2 | yes | operations | command | `20 * * * *` | 64 | 64 | 64 | 0 | 0 | 0 | 212 | 1450 | 0.45 | `python3 scripts/credit-proof.py stage2 --max-users 40` |
| main | credit-verify-proof-intercom | yes | operations | command | `5,35 * * * *` | 64 | 32 | 64 | 0 | 0 | 13 | 26 | 420 | 0.23 | `python3 scripts/credit-proof.py intercom --days 2 --max-files 300` |
| main | heartbeat-clio | yes | clio | heartbeat | `1800000` | 9 | 168 | 0 | 7 | 2 | 600 | 600 | 600 | 0.17 | agent turn |
| edge | heartbeat-support | yes | support | heartbeat | `1800000` | 64 | 32 | 0 | 0 | 64 | 0 | 64 | 183 | 0.16 | agent turn |
| main | support-email-triage-hourly | yes | operations | agentTurn | `0 * * * *` | 64 | 124 | 63 | 1 | 0 | 41 | 75 | 125 | 0.15 | agent turn |
| main | credit-jan-tray-0700 | yes | operations | command | `0 7 * * *` | 7 | 168 | 7 | 0 | 0 | 475 | 687 | 687 | 0.15 | `bash scripts/credit-jan-tray-dm.sh` |
| main | credit-provisional-tracker-0600 | yes | operations | command | `0 6 * * *` | 9 | 168 | 0 | 9 | 0 | 26 | 600 | 600 | 0.09 | `python3 scripts/credit-review.py provisional-tracker --out /var/lib/hydra/credit` |
| main | daily-dispute-handler | yes | finance | agentTurn | `0 9 * * *` | 7 | 168 | 7 | 0 | 0 | 166 | 778 | 778 | 0.08 | agent turn |
| main | caroline-daily-review | yes | operations | agentTurn | `0 9 * * *` | 7 | 168 | 7 | 0 | 0 | 251 | 349 | 349 | 0.07 | agent turn |
| main | credit-verification-fraud-muso-only-snapshot | yes | operations | command | `0 3 * * *` | 7 | 168 | 7 | 0 | 0 | 231 | 308 | 308 | 0.07 | `bash workspaces/operations/skills/muso-ops-credit-verification/scripts/lib/fraud` |
| main | Realtime MRR Movement | yes | finance | command | `*/5 * * * *` | 64 | 5 | 64 | 0 | 0 | 1 | 1 | 2 | 0.07 | `python3 workspaces/finance/scripts/stripe-saas-realtime-report.py` |
| main | systemic-data-issue-report-daily | yes | operations | agentTurn | `0 6 * * *` | 7 | 168 | 7 | 0 | 0 | 162 | 233 | 233 | 0.05 | agent turn |
| main | Daily SaaS Recap | yes | finance | command | `0 6 * * *` | 7 | 168 | 7 | 0 | 0 | 167 | 177 | 177 | 0.05 | `python3 workspaces/finance/scripts/stripe-saas-daily-report.py` |
| main | credit-profile-link-proposals | yes | operations | command | `45 * * * *` | 64 | 64 | 64 | 0 | 0 | 0 | 10 | 10 | 0.02 | `python3 scripts/credit-dsp-verify.py link-proposals` |
| main | company-finder-daily | yes | scout | agentTurn | `0 13 * * *` | 7 | 168 | 7 | 0 | 0 | 54 | 149 | 149 | 0.02 | agent turn |
| main | caroline-weekly-rollup | yes | operations | agentTurn | `0 10 * * 1` | 1 | 168 | 1 | 0 | 0 | 399 | 399 | 399 | 0.02 | agent turn |
| main | Ad screening | yes | devops | command | `*/5 * * * *` | 64 | 5 | 64 | 0 | 0 | 0 | 0 | 2 | 0.01 | `bash scripts/ad-screening.sh --run` |
| main | Weekly SaaS Recap | yes | finance | command | `30 5 * * 1` | 1 | 168 | 1 | 0 | 0 | 342 | 342 | 342 | 0.01 | `python3 workspaces/finance/scripts/stripe-saas-weekly-report.py` |
| main | hydra-health-watch-twice-daily | yes | scout | agentTurn | `5 9,21 * * *` | 14 | 168 | 14 | 0 | 0 | 16 | 101 | 101 | 0.01 | agent turn |
| main | credit-fleet-fraud-scan-weekly | yes | operations | agentTurn | `0 9 * * 1` | 1 | 168 | 1 | 0 | 0 | 277 | 277 | 277 | 0.01 | agent turn |
| main | codex-usage-report-aaron-twice-daily | yes | devops | agentTurn | `1 9,22 * * *` | 14 | 168 | 14 | 0 | 0 | 11 | 17 | 17 | 0.01 | agent turn |
| edge | Memory Dreaming Promotion | yes | - | agentTurn | `0 3 * * *` | 4 | 168 | 4 | 0 | 0 | 41 | 49 | 49 | 0.01 | agent turn |
| main | codex-usage-report-nick-twice-daily | yes | devops | agentTurn | `2 9,22 * * *` | 14 | 168 | 14 | 0 | 0 | 11 | 17 | 17 | 0.01 | agent turn |
| main | caroline-autonomy-improver | yes | cto | agentTurn | `30 11 * * 1` | 1 | 168 | 1 | 0 | 0 | 133 | 133 | 133 | 0.01 | agent turn |
| main | zak-waxman-proof-reply-watch | no | clio | command | `1800000` | 64 | 57 | 62 | 2 | 0 | 0 | 1 | 1 | 0.00 | `python3 workspaces/coordinator/scripts/zak-proof-monitor.py` |
| main | credit-approval-audit-metrics-weekly | yes | operations | command | `20 8 * * 1` | 1 | 168 | 1 | 0 | 0 | 61 | 61 | 61 | 0.00 | `python3 scripts/credit-review.py metrics --days 7` |
| main | credit-decide-watchdog-hourly | yes | operations | command | `17 * * * *` | 64 | 64 | 64 | 0 | 0 | 0 | 0 | 1 | 0.00 | `bash scripts/credit-decide-watchdog.sh` |
| main | godmode-actions-weekly-report | yes | devops | agentTurn | `0 9 * * 1` | 1 | 168 | 1 | 0 | 0 | 42 | 42 | 42 | 0.00 | agent turn |
| main | credit-digest-dm-0800-ny | yes | operations | command | `0 8 * * *` | 7 | 168 | 7 | 0 | 0 | 2 | 3 | 3 | 0.00 | `bash scripts/credit-digest-dm.sh` |
| main | credit-approval-audit-digest-daily | yes | operations | command | `15 8 * * *` | 7 | 168 | 7 | 0 | 0 | 0 | 2 | 2 | 0.00 | `python3 scripts/credit-review.py digest --hours 24` |
| main | credit-trust-score-approve-15m | no | operations | command | `10,25,40,55 * * * *` | 9 | 168 | 9 | 0 | 0 | 0 | 3 | 3 | 0.00 | `python3 scripts/credit-review.py score-approve --mode apply` |
| main | credit-decide-watchdog-shadow-daily | yes | operations | command | `17 7 * * *` | 6 | 168 | 6 | 0 | 0 | 0 | 0 | 0 | 0.00 | `bash scripts/credit-decide-watchdog.sh --shadow-report` |
| main | Memory Dreaming Promotion | yes | clio | agentTurn | `0 3 * * *` | 0 | 168 | 0 | 0 | 0 | 0 | 0 | 0 | 0.00 | agent turn |
| main | qa-autoreview-pr-Muso-AI-ios-app-445 | yes | qa | agentTurn | `at` | 1 | 168 | 0 | 0 | 1 | 0 | 0 | 0 | 0.00 | agent turn |

Not listed: 39 jobs that are disabled and have no receipt in the last 7 days.

Totals, recurring jobs only: main profile command jobs **19.29 wall h/day**, main profile agent
turns and heartbeat 0.59, edge profile 0.16. The top three rows
(`credit-trust-decide-15m`, `credit-verify-proof-file`, `credit-dsp-verify-d5b`) are 14.20 of that.

What the receipts say about those three:

- `credit-trust-decide-15m`: p50 255 s, p95 287 s inside a 900 s slot, so the decider is running
  for a little over a quarter of every hour. 61 ok of 65; the 3 errors were one `Gateway shutting
  down.`, one `command stopped by signal SIGTERM`, one `command exited with code 1`.
- `credit-verify-proof-file`: 17 of 65 runs ended `cron: job execution timed out` at 3,000 s.
  The other runs have a p50 of 0 s. This job's wall time is almost entirely its timeouts.
- `credit-dsp-verify-d5b`: 9 of 64 ended `command exited with code 1`, after 29 to 1,246 s.

Two jobs did not succeed once in the window: `credit-provisional-tracker-0600` (0 ok of 9: exit
code 1 or a 600 s timeout) and `heartbeat-clio` (0 ok of 9: seven 600 s timeouts, two
`heartbeat skipped: no-route`). Why they fail was not investigated here.

## Gateway cron: one-shot jobs (created, run once, deleted)

These have a receipt but no row left in `cron_jobs`. Seven-day window, main profile:

| agent | runs in 7 d | per hour | ok | error | other | total wall h | mean s | max s |
|---|---|---|---|---|---|---|---|---|
| qa | 4,154 | 24.7 | 3,768 | 385 | 1 | 212.84 | 184 | 693 |
| operations | 654 | 3.9 | 639 | 15 | 0 | 44.48 | 245 | 845 |
| clio | 266 | 1.6 | 7 | 173 | 86 | 34.37 | 465 | 604 |
| cto | 21 | 0.1 | 21 | 0 | 0 | 2.79 | 479 | 1,694 |

Edge profile: 3 (all `support`, all error, 0.03 wall h).

- The `qa` rows are PR auto-reviews (the one still present in `cron_jobs` is named
  `qa-autoreview-pr-Muso-AI-ios-app-445`). 212.84 wall hours in 168 hours is an average of
  **1.27 QA review sessions in flight at any moment, inside the main gateway process**.
- What the `operations` and `cto` one-shot jobs are was not established (their names are gone
  with the job row).
- `clio`: 172 of 266 ended `cron: job execution timed out`, 83 `heartbeat skipped: no-route`.

## Host cron

### Root crontab (8 lines)

| schedule | command |
|---|---|
| `*/10 * * * *` | `/opt/muso-sync/hydra-audit-push.sh` |
| `0 9 * * 1` | `/opt/hydra/scripts/cron-muso-outreach-monday.sh` |
| `17 9 * * 1` | `/opt/hydra/scripts/memory-health-check.sh` |
| `1 * * * *` | `/opt/firstmate/fraud-lens/cron_tick.sh` |
| `*/15 * * * *` | `/usr/local/bin/infra-sweep-mon.sh` |
| `50 13 * * *` | `/usr/local/bin/infra-sweep-mon.sh --daily` |
| `*/5 * * * *` | `/usr/local/bin/post-release-watch.sh` |
| `7 * * * *` | `cd /opt/muso-sync/ops-completeness \|\| exit 1; CT_BOARD_URL=http://10.43.124.251:3000 PUSHGATEWAY_URL=http://10.43.21.81:9091 python3 completeness-sn` |

### /etc/cron.d

| file | read by cron | schedule | command |
|---|---|---|---|
| ads-inquiry-watchdog | yes | `*/15 * * * *` | `USE_MUSO_CLI=1 MUSO_BIN=/usr/local/bin/muso /opt/hydra/scripts/ads-inquiry-watchdog.sh` |
| agent-soul-delivery-guard | yes | `*/15 * * * *` | `/opt/hydra/scripts/check-agent-soul-delivery.sh --alert` |
| caroline-rag-index-watchdog | yes | `*/10 * * * *` | `/opt/hydra/scripts/caroline-rag-index-watchdog.sh` |
| caroline-rag-index-watchdog | yes | `5-59/10 * * * *` | `CAROLINE_RAG_PROFILE=main CAROLINE_RAG_AGENT=cmo CAROLINE_RAG_HEAL_AGENTS='cmo cto finance ceo operations devops' CAROLINE_RAG_LOCKFILE=/var/run/carol` |
| claim-proof-check-c2 | yes | `30 * * * *` | `CLAIM_PROOF_SECRET_FILE=*** /usr/bin/flock -n /run/claim-proof-check-c2.lock /opt/claim-lane-c2/core-backend/scripts/claim-proof-check-cron.sh` |
| codex-keepalive | yes | `*/15 * * * *` | `CODEX_KEEPALIVE_PROFILES="main edge" /opt/hydra/scripts/codex-keepalive.sh` |
| codex-quota-refresh | yes | `*/20 * * * *` | `flock -n /run/lock/codex-quota-refresh.lock /opt/hydra/scripts/codex-quota-refresh.sh` |
| credit-decider-support-watch | yes | `*/30 * * * *` | `python3 /opt/hydra/scripts/credit-decider-support-watch.py --json` |
| credit-outbound-watchdog | yes | `*/15 * * * *` | `/usr/bin/python3 /opt/hydra/scripts/credit-outbound-watchdog.py` |
| credit-verify-outbound | yes | `0 */2 * * *` | `/opt/hydra/scripts/credit-verify-outbound.sh` |
| credit-verify-outbound.bak-scale.disabled | no (dot in name) | `0 */2 * * *` | `/opt/hydra/scripts/credit-verify-outbound.sh` |
| credit-verify-outbound.disabled-20261111 | no (dot in name) | `*/30 * * * *` | `/opt/hydra/scripts/credit-verify-outbound.sh` |
| cron-health-watchdog | yes | `*/5 * * * *` | `/opt/hydra/scripts/cron-health-watchdog.sh` |
| cs-credit-proof-file | yes | `37 */2 * * *` | `/usr/local/bin/cs-credit-proof-file.sh` |
| cs-email-filing-watch | yes | `*/10 * * * *` | `/usr/local/bin/cs-email-filing-watch.sh` |
| cs-novelty-watch | yes | `47 * * * *` | `[ "$(date -u +%FT%TZ)" \> "2026-11-09T00:00:00Z" ] \|\| /usr/local/bin/cs-novelty-watch.py` |
| cs-proof-quota-guard | yes | `*/5 * * * *` | `/usr/local/bin/cs-proof-quota-guard.sh` |
| cs-systemic-support-intake | yes | `17 */2 * * *` | `cd /root/fmc1-intake && timeout 900 python3 support-intake.py --since-hours 3 --label --page --report` |
| cs-systemic-support-intake.paused-0241 | no (dot in name) | `17 */2 * * *` | `cd /root/fmc1-intake && timeout 900 python3 support-intake.py --since-hours 3 --label --page --report` |
| e2scrub_all | yes | `30 3 * * 0` | `test -e /run/systemd/system \|\| SERVICE_MODE=1 /usr/lib/x86_64-linux-gnu/e2fsprogs/e2scrub_all_cron` |
| e2scrub_all | yes | `10 3 * * *` | `test -e /run/systemd/system \|\| SERVICE_MODE=1 /sbin/e2scrub_all -A -r` |
| fallback-swallow-watchdog | yes | `*/5 * * * *` | `/opt/hydra/scripts/fallback-swallow-watchdog.sh` |
| ghl-api-watchdog | yes | `20 6 * * *` | `MUSO_BIN=/usr/local/bin/muso /opt/hydra/scripts/ghl-api-watchdog.sh` |
| hydra-churn-risk | yes | `15 4 * * *` | `/opt/hydra/scripts/churn/nightly.sh` |
| hydra-churn-risk | yes | `20 * * * *` | `/opt/hydra/scripts/churn/cancel_with_open_issue.sh` |
| hydra-churn-risk | yes | `0 8 * * 1` | `/opt/hydra/scripts/churn/weekly_line.sh` |
| hydra-claim-status | yes | `15 1 * * *` | `MODE=dry-run /opt/hydra/scripts/claim-status-daily.sh` |
| hydra-cs-proof-feed | yes | `21 * * * *` | `systemd-cat -t hydra-cs-proof-feed /opt/hydra/scripts/cs-proof-feed.sh` |
| hydra-cs-proof-feed.paused-20261031T0153 | no (dot in name) | `21 * * * *` | `systemd-cat -t hydra-cs-proof-feed /opt/hydra/scripts/cs-proof-feed.sh` |
| hydra-paid-status | yes | `30 0 * * *` | `MODE=apply EMAIL_ROUTE=1 SEGMENTS="paid" /opt/hydra/scripts/paid-status/daily.sh` |
| hydra-paid-status | yes | `0 15 * * *` | `MODE=apply EMAIL_ROUTE=1 SEGMENTS="paid free" /opt/hydra/scripts/paid-status/daily.sh` |
| hydra-verification-steward | yes | `7,37 * * * *` | `[ -e /etc/hydra/verification-steward.disabled ] \|\| flock -n /run/hydra-verification-steward.lock timeout 1500 python3 /var/lib/hydra/verification-st` |
| hydra-verification-steward | yes | `22,52 * * * *` | `[ -e /etc/hydra/verification-steward.disabled ] \|\| flock -n /run/hydra-verification-steward-done.lock timeout 1500 python3 /var/lib/hydra/verificati` |
| hydra-verification-steward | yes | `5 5,17 * * *` | `[ -e /etc/hydra/verification-steward.disabled ] \|\| flock -n /run/hydra-verification-steward-ledger.lock timeout 3000 python3 /var/lib/hydra/verifica` |
| hydra-verification-steward | yes | `40 8,16 * * *` | `[ -e /etc/hydra/verification-steward.disabled ] \|\| flock -n /run/hydra-verification-steward-ledger.lock timeout 3000 python3 /var/lib/hydra/verifica` |
| hydra-verification-steward | yes | `38 * * * *` | `[ -e /etc/hydra/verification-steward.disabled ] \|\| flock -n /run/hydra-verification-steward-monitor.lock timeout 1500 python3 /var/lib/hydra/verific` |
| hydra-verification-steward | yes | `50 * * * *` | `[ -e /etc/hydra/verification-steward.disabled ] \|\| python3 /var/lib/hydra/verification-steward/l11read-v2.py` |
| hydra-verification-steward | yes | `35 0-22/2 * * *` | `/var/lib/hydra/verification-steward/bin/board2h.sh` |
| hydra-verifier-eval | yes | `40 4 * * *` | `flock -n /run/lock/hydra-verifier-eval.lock python3 /opt/hydra/scripts/verifier-eval.py nightly --root /var/lib/hydra/verifier-eval` |
| mercury-token-watchdog | yes | `45 8 * * *` | `MUSO_BIN=/usr/local/bin/muso /opt/hydra/scripts/mercury-token-watchdog.sh` |
| merge-landing-watchdog | yes | `*/30 * * * *` | `/opt/hydra/scripts/merge-landing-watchdog.sh` |
| merge-queue-census | yes | `*/30 * * * *` | `cd /root/q1 && bash -c 'set -a; . /etc/openclaw/main.env; . /etc/openclaw/edge.env; set +a; python3 clickup_merges.py > clickup.json.tmp && mv clickup` |
| merge-queue-variant-queue | yes | `17 10 * * *` | `cd /root/q1 && bash -c 'set -a; . /etc/openclaw/main.env; . /etc/openclaw/edge.env; set +a; python3 plan.py clickup.json m1_sel.json` |
| openclaw-watchdog | yes | `*/2 * * * *` | `/opt/hydra/scripts/openclaw-watchdog.sh` |
| ops-completeness | yes | `7 * * * *` | `cd /opt/hydra/credit-trust-board && CT_BOARD_URL=http://10.43.124.251:3000 PUSHGATEWAY_URL=http://10.43.21.81:9091 timeout 1500 python3 completeness-s` |
| prod-log-alert-watchdog | yes | `*/5 * * * *` | `/opt/hydra/scripts/prod-log-alert-watchdog.sh` |
| refund-credit-overlap-watchdog | yes | `17 7 * * *` | `/opt/hydra/scripts/refund-credit-overlap-watchdog.sh` |
| sentry-issue-watchdog | yes | `*/30 * * * *` | `/opt/hydra/scripts/sentry-issue-watchdog.sh` |
| slack-freeze-miss-check | yes | `*/5 * * * *` | `/opt/hydra/scripts/slack-freeze-miss-check.sh` |
| stale-ticket-watchdog | yes | `30 8 * * *` | `USE_MUSO_CLI=1 MUSO_BIN=/usr/local/bin/muso /opt/hydra/scripts/stale-ticket-watchdog.sh` |
| stuck-lane-watchdog | yes | `*/2 * * * *` | `/opt/hydra/scripts/stuck-lane-watchdog.sh` |
| sysstat | yes | `5-55/10 * * * *` | `command -v debian-sa1` |
| sysstat | yes | `59 23 * * *` | `command -v debian-sa1` |
| verification-queue-report | yes | `*/30 * * * *` | `flock -n /run/lock/verification-queue-report.lock python3 /opt/hydra/scripts/verification-queue-report.py --post` |
| verification-queue-report | yes | `*/5 * * * *` | `flock -n /run/lock/verification-queue-report-light.lock python3 /opt/hydra/scripts/verification-queue-report.py --light --post` |

4 of the `/etc/cron.d` rows are in files whose name contains a dot (`*.disabled-*`, `*.paused-*`,
`*.bak-*`). Debian cron only reads `/etc/cron.d` files named with letters, digits, `_` and `-`
(cron(8), run-parts naming), so those rows are inert copies. That is documented behaviour; it was
not confirmed here by watching cron skip them.

Not under `/opt/hydra`, so not shipped by the hydra deploy: `/opt/firstmate/fraud-lens/cron_tick.sh`,
`/var/lib/hydra/verification-steward/bin/*` (seven entries), `/usr/local/bin/cs-*` (four),
`/root/q1/*.py` (two), `/root/fmc1-intake/support-intake.py`, `/opt/claim-lane-c2/core-backend/...`,
`/opt/muso-sync/*` (two), `/usr/local/bin/infra-sweep-mon.sh`, `/usr/local/bin/post-release-watch.sh`.

## systemd timers

CPU and memory are what systemd recorded for the unit's **most recent run** (`CPUUsageNSec`,
`MemoryPeak`); `n/a` means systemd did not keep the figure. One run, not an average.

### systemd timers

| timer | schedule | command | last run CPU s | last run mem peak MiB | last result |
|---|---|---|---|---|---|
| apt-daily | `OnCalendar=*-*-* 06,18:00:00` | `/usr/lib/apt/apt.systemd.daily update ` | 0.3 | 3 | success |
| apt-daily-upgrade | `OnCalendar=*-*-* 06:00:00` | `/usr/lib/apt/apt.systemd.daily install ` | 0.3 | n/a | success |
| caroline-behavior-digest | `OnCalendar=*-*-* 16:00:00 UTC` | `/usr/bin/python3 /opt/hydra/scripts/caroline-behavior-digest.py --post ` | 0.2 | n/a | success |
| caroline-monitor | `OnUnitActiveUSec=2h OnBootUSec=10min` | `/usr/bin/python3 /opt/hydra/scripts/caroline-monitor.py tick ` | 0.7 | n/a | success |
| caroline-safety-daily | `OnCalendar=*-*-* 06:10:00 UTC` | `/bin/bash /opt/hydra/scripts/caroline-safety-daily.sh ` | 0.4 | n/a | success |
| claim-list-build | `OnCalendar=*-*-* 01/2:20:00` | `/usr/bin/python3 /opt/hydra/scripts/claim-list-build.py ` | 66.7 | n/a | success |
| clickup-drain-data-deletion | `OnCalendar=*-*-* *:25:00` | `/usr/bin/python3 /opt/hydra/scripts/clickup_drain/data_deletion.py --apply ` | 0.2 | n/a | exit-code |
| clickup-drain-profile-claim | `OnCalendar=*-*-* *:35:00` | `/usr/bin/python3 /opt/hydra/scripts/clickup_drain/profile_claim.py --apply --max-writes 100 ` | 4.2 | n/a | success |
| clickup-sla-digest | `OnCalendar=*-*-* 08:10:00 America/New_York` | `/opt/hydra/scripts/clickup-sla-digest.sh ` | 14.2 | n/a | success |
| clickup-todo-dedupe | `OnCalendar=*-*-* *:40:00` | `/usr/bin/python3 /opt/hydra/scripts/clickup-todo-dedupe.py ` | 0.3 | n/a | success |
| close-duplicate-conversations | `OnCalendar=*-*-* 10:00:00 UTC` | `/usr/bin/python3 /opt/hydra/scripts/close-duplicate-conversations.py --notify-candidates ` | 2.3 | n/a | success |
| close-merged-tickets | `OnCalendar=*-*-* 07:12:00 UTC` | `/opt/hydra/scripts/dedup/sweeps/close-merged-tickets.sh --apply ` | 7.9 | n/a | exit-code |
| close-resolved-conversations | `OnCalendar=*-*-* 02,08,14,20:25:00 UTC` | `/usr/bin/python3 /opt/hydra/scripts/close-resolved-conversations.py --apply --notify ` | 3.3 | n/a | success |
| codex-canonical-refresh | `OnCalendar=Wed,Sun *-*-* 04:00:00 UTC` | `/opt/hydra/scripts/codex-canonical-refresh.sh ` | 3.5 | n/a | success |
| codex-edge-mirror | `OnCalendar=*-*-* 04:30:00 UTC` | `/opt/hydra/scripts/lib/codex-edge-mirror.sh --restart ` | 0.1 | n/a | success |
| credit-precedent | `OnUnitActiveUSec=15min OnBootUSec=6min` | `/bin/bash -lc POD=$(kubectl -n muso-prod get pod -l app=core-backend-api --no-headers -o custom-columns=:metadata.name \` | 0.4 | 35 | success |
| cs-needs-human-digest-delta | `OnCalendar=*-*-* 19:30:00 UTC OnCalendar=*-*-* 07:30:00 UTC` | `/usr/bin/python3 /opt/hydra/scripts/cs-needs-human-digest.py --post --delta ` | 4.7 | n/a | success |
| cs-needs-human-digest | `OnCalendar=*-*-* 13:30:00 UTC` | `/usr/bin/python3 /opt/hydra/scripts/cs-needs-human-digest.py --post ` | 4.8 | n/a | success |
| cs-selfserve-backlog-collect | `OnCalendar=*-*-* 02:30:00 UTC` | `/usr/bin/python3 /opt/hydra/scripts/cs-selfserve-backlog.py --collect ` | 0.9 | n/a | success |
| cs-selfserve-backlog | `OnCalendar=*-*-01 09:00:00 UTC` | `/usr/bin/python3 /opt/hydra/scripts/cs-selfserve-backlog.py --post ` | 0.8 | n/a | success |
| cs-sla-report | `OnCalendar=Mon *-*-* 08:30:00 UTC` | `/usr/bin/python3 /opt/hydra/scripts/cs-sla-report.py --post ` | 0.5 | n/a | success |
| devops-envset-vault-renew | `OnCalendar=Mon *-*-* 00:00:00` | `/usr/local/sbin/devops-envset-vault-renew.sh ` | 0.0 | n/a | success |
| dpkg-db-backup | `OnCalendar=*-*-* 00:00:00` | `/usr/libexec/dpkg/dpkg-db-backup ` | 0.0 | n/a | success |
| e2scrub_all | `OnCalendar=Sun *-*-* 03:10:00` | `/sbin/e2scrub_all ` | 0.0 | n/a | success |
| fstrim | `OnCalendar=Mon *-*-* 00:00:00` | `/sbin/fstrim --listed-in /etc/fstab:/proc/self/mountinfo --verbose --quiet-unsupported ` | 3.4 | n/a | success |
| gdpr-hide-batch | `OnCalendar=*-*-* 00,06,12,18:20:00 UTC` | `/usr/bin/python3 /opt/hydra/scripts/gdpr-pipeline.py hide-batch --open-prs ` | 43.9 | 40 | success |
| gdpr-pipeline-tick | `OnUnitActiveUSec=1h OnBootUSec=20min` | `/usr/bin/python3 /opt/hydra/scripts/gdpr-pipeline.py tick --page --send --limit 25 --approved-by $GDPR_SENDER_SEAT ` | 53.2 | n/a | success |
| hydra-approval-stamps-audit | `OnUnitActiveUSec=15min OnBootUSec=15min` | `/bin/bash /opt/hydra/scripts/audit-approval-stamps.sh ` | 0.1 | n/a | exit-code |
| hydra-company-finder-cache-refresh | `OnCalendar=*-*-* *:00/15:00` | `/usr/bin/bash -lc set -a` | 6.6 | n/a | success |
| hydra-daily-audit | `OnCalendar=*-*-* 08:00:00 UTC` | `/opt/hydra/scripts/hydra-daily-audit.py ` | 1.0 | n/a | success |
| hydra-jev-shadow-prune | `OnCalendar=*-*-* 05:15:00 UTC` | `/opt/hydra/scripts/jev-shadow-prune.sh ` | 215.5 | n/a | success |
| hydra-main-prune-restart | `OnCalendar=*-*-* 02:30:00 UTC` | `/opt/hydra/scripts/main-prune-restart.sh nightly ` | 45.5 | n/a | success |
| hydra-peer-labels | `OnUnitActiveUSec=5min OnBootUSec=2min` | `/opt/hydra/scripts/provision-peer-labels.sh main ` | 14.1 | n/a | success |
| hydra-refund-confirm-audit | `OnUnitActiveUSec=30min OnBootUSec=30min` | `/bin/bash /opt/hydra/scripts/audit-refund-confirmations.sh ` | 1.1 | n/a | exit-code |
| hydra-release-digest | `OnCalendar=*-*-* 08:00:00 America/New_York` | `/opt/hydra/scripts/release-digest.sh ` | 2.5 | n/a | success |
| hydra-release-watch | `OnUnitActiveUSec=5min OnBootUSec=5min` | `/opt/hydra/scripts/release-watch.sh ` | 0.5 | n/a | success |
| hydra-session-thread-retention@edge | `OnUnitActiveUSec=6h OnBootUSec=20min` | `/opt/hydra/scripts/prune-completed-slack-thread-sessions.sh --profile edge --apply ` | 2.8 | n/a | success |
| hydra-session-thread-retention@main | `OnUnitActiveUSec=6h OnBootUSec=20min` | `/opt/hydra/scripts/prune-completed-slack-thread-sessions.sh --profile main --apply ` | 21.5 | n/a | success |
| hydra-tmp-reaper | `OnCalendar=*-*-* *:00:00` | `/opt/hydra/scripts/tmp-reaper.sh ` | 9.5 | n/a | success |
| hydra-weekly-cleanup | `OnCalendar=Mon *-*-* 04:30:00 UTC` | `/opt/hydra/scripts/clean-my-linux.sh --apply ` | 2167.7 | 2920 | success |
| intercom-intake-watchdog | `OnUnitActiveUSec=2h OnBootUSec=10min` | `/usr/bin/python3 /opt/hydra/scripts/intercom-intake-watchdog.py --alert ` | 0.1 | n/a | success |
| intercom-legal-unanswered-watchdog | `OnUnitActiveUSec=1h OnBootUSec=15min` | `/usr/bin/python3 /opt/hydra/scripts/intercom-legal-unanswered-watchdog.py ` | 0.3 | n/a | success |
| intercom-rights-holder-watchdog | `OnUnitActiveUSec=10min OnBootUSec=10min` | `/usr/bin/python3 /opt/hydra/scripts/intercom-rights-holder-watchdog.py ` | 0.1 | n/a | success |
| logrotate | `OnCalendar=*-*-* 00:00:00` | `/usr/sbin/logrotate /etc/logrotate.conf ` | 0.4 | n/a | success |
| merge-outcome-notify | `OnCalendar=*-*-* *:05/15:00` | `/usr/bin/python3 /opt/hydra/scripts/merge-outcome-notify.py --apply ` | 0.2 | n/a | success |
| model-chain-watchdog | `OnUnitActiveUSec=15min OnBootUSec=5min` | `/usr/bin/python3 /opt/hydra/scripts/model-chain-watchdog.py --alert ` | 0.1 | n/a | success |
| motd-news | `OnStartupUSec=1min OnCalendar=*-*-* 00,12:00:00` | `/etc/update-motd.d/50-motd-news --force ` | 0.0 | n/a | success |
| ops-intake-digest | `OnCalendar=*-*-* 07:00:00 UTC` | `/usr/bin/python3 /opt/hydra/scripts/ops_intake/watcher.py digest --post ` | 0.1 | n/a | success |
| ops-intake-redteam | `OnCalendar=*-*-* 06:40:00 UTC` | `/bin/bash /opt/hydra/scripts/ops-intake-redteam-daily.sh ` | 0.5 | n/a | success |
| overdue-verification-notifier | `OnCalendar=*-*-* 09:12:00 UTC` | `/usr/bin/python3 /opt/hydra/scripts/overdue-verification-notifier.py --apply ` | 1.7 | n/a | success |
| prometheus-node-exporter-apt | `OnUnitActiveUSec=15min OnBootUSec=0` | `/bin/bash -c /usr/share/prometheus-node-exporter-collectors/apt_info.py \| sponge /var/lib/prometheus/node-exporter/apt.` | 0.6 | n/a | success |
| prometheus-node-exporter-ipmitool-sensor | `OnUnitActiveUSec=1min OnBootUSec=0` | `/bin/sh -c /usr/bin/ipmitool sensor \| /usr/share/prometheus-node-exporter-collectors/ipmitool \| sponge /var/lib/promet` | 0.1 | n/a | success |
| prometheus-node-exporter-mellanox-hca-temp | `OnUnitActiveUSec=1min OnBootUSec=0` | `/bin/sh -c /usr/share/prometheus-node-exporter-collectors/mellanox_hca_temp \| sponge /var/lib/prometheus/node-exporter/` | n/a | n/a | success |
| prometheus-node-exporter-nvme | `OnUnitActiveUSec=15min OnBootUSec=0` | `/bin/sh -c /usr/share/prometheus-node-exporter-collectors/nvme_metrics.py \| sponge /var/lib/prometheus/node-exporter/nv` | 0.1 | n/a | success |
| prometheus-node-exporter-smartmon | `OnUnitActiveUSec=15min OnBootUSec=0` | `/bin/bash -c /usr/share/prometheus-node-exporter-collectors/smartmon.sh \| sponge /var/lib/prometheus/node-exporter/smar` | n/a | n/a | success |
| qa-approval-retry | `OnUnitActiveUSec=30min` | `/opt/hydra/scripts/qa-approval-retry.sh ` | 66.0 | n/a | success |
| qa-review-reconcile | `OnUnitActiveUSec=1h` | `/opt/hydra/scripts/qa-review-reconcile.sh ` | 159.7 | n/a | success |
| request-comms | `OnCalendar=*-*-* *:40:00` | `/usr/bin/python3 /opt/hydra/scripts/request-comms.py tick --live --json ` | 32.5 | n/a | exit-code |
| resolution-matcher | `OnCalendar=*-*-* 12:14:00 UTC` | `/usr/bin/python3 /opt/hydra/scripts/resolution-matcher.py --apply ` | 165.2 | n/a | success |
| resolve-notify | `OnCalendar=*-*-* 02,08,14,20:25:00 UTC` | `/usr/bin/python3 /opt/hydra/scripts/resolve-notify.py --apply ` | 0.2 | n/a | success |
| sentinel-demote-fast | `OnUnitActiveUSec=1h OnBootUSec=7min` | `/usr/bin/python3 /opt/hydra/scripts/sentinel/demote.py run --fast --mirror-repo /var/lib/hydra/sentinel/mirror-repo ` | 0.0 | n/a | success |
| sentinel-demote | `OnCalendar=*-*-* 02:30:00 UTC` | `/usr/bin/python3 /opt/hydra/scripts/sentinel/demote.py run --nightly --mirror-repo /var/lib/hydra/sentinel/mirror-repo ` | 0.0 | n/a | success |
| sentinel-propose | `OnCalendar=Sun *-*-* 02:00:00 UTC` | `/usr/bin/python3 /opt/hydra/scripts/sentinel/demote.py propose --open-pr --mirror-repo /var/lib/hydra/sentinel/mirror-re` | 1.0 | n/a | success |
| support-changelog-sync | `OnCalendar=*-*-* 05:30:00 UTC` | `/opt/hydra/scripts/support-changelog-sync.sh ` | 39.5 | n/a | success |
| support-resolution-daily | `OnCalendar=*-*-* 06:30:00 UTC` | `/bin/bash /opt/hydra/scripts/support-resolution-daily.sh ` | n/a | n/a | success |
| sync-app-pricing | `OnCalendar=*-*-* 05:50:00 UTC` | `/opt/hydra/scripts/sync-app-pricing.sh ` | 0.1 | n/a | success |
| sync-platform-llms | `OnCalendar=*-*-* 05:45:00 UTC` | `/opt/hydra/scripts/sync-platform-llms.sh ` | 0.0 | n/a | success |
| sysstat-collect | `OnCalendar=*-*-* *:00/10:00` | `/usr/lib/sysstat/sa1 1 1 ` | 0.0 | n/a | success |
| sysstat-summary | `OnCalendar=*-*-* 00:07:00` | `/usr/lib/sysstat/sa2 -A ` | 0.8 | n/a | success |
| systemd-tmpfiles-clean | `OnUnitActiveUSec=1d OnBootUSec=15min` | `systemd-tmpfiles --clean ` | 1.1 | n/a | success |
| ua-timer | `OnStartupUSec=1min OnUnitActiveUSec=6h` | `/usr/bin/python3 /usr/lib/ubuntu-advantage/timer.py ` | n/a | n/a | success |

Reading the timer table: 67 of 71 have a CPU figure. Apart from `hydra-weekly-cleanup`
(2,167.7 CPU-seconds, weekly, memory peak 2,920 MiB), no timer used more than 216 CPU-seconds on
its last run. Five ended their last run with a non-zero exit: `clickup-drain-data-deletion`,
`close-merged-tickets`, `hydra-approval-stamps-audit`, `hydra-refund-confirm-audit`, `request-comms`.
The cause of those exits was not investigated here.

