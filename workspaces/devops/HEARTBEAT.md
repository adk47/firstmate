# HEARTBEAT.md — DevOps Agent

⛔ ALL AUTOMATIONS DISABLED — Running on Clio until cutover

## ⚠️ POSTING RULE
All heartbeat output → MAIN CHANNEL (top-level), never in a thread. Use `message(action=send, target=<channel_id>)` with NO `threadId`/`replyTo`.

---

## Commit Review — Critical Repos → #devops_opsworks (C0ACLSLFXAR)
**Status: DISABLED — awaiting cutover from Clio**

Scan 24h commits: `platform-data-processing`, `industry-data-processing`, `core-backend`, `devops`. Flag schema/contract changes. Cross-ref removed columns.
⚠️ Was #clio_devops — Aaron moved all my output to #devops_opsworks (Mar 16, 2026). I do NOT post to #clio_devops at all.

---

## Industry Realtime Import Freshness
**Status: DISABLED — awaiting cutover from Clio**

Check S3 checkpoint timestamps at `s3://platform-data-processing-lake-prod/industry/materialize_realtime_checkpoints/`. Alert if >8h stale.

---

## AWS Infrastructure Monitoring
**Status: DISABLED — awaiting cutover from Clio**

CloudWatch alarms, CloudTrail infra changes, EKS health, MWAA failed DAGs, cost spikes. Post root cause to #devops_opsworks (C0ACLSLFXAR).

---

## Webshare ISP Proxy Health (Self-Healing)
**Status: DISABLED — awaiting cutover from Clio**

Check `GET /api/v2/proxy/config/?plan_id=12838270`. If `unallocated_countries` non-empty → auto-reallocate to EU countries. Post to #devops_opsworks.

---

## GitHub API Key Leak Scan (3x daily)
**Status: DISABLED — awaiting cutover from Clio**

Run `scripts/gh-key-scanner.sh`. Only alert if leak found → post to #devops_opsworks. Stay silent if clean.

---

## Daily Write Activity Report → #devops_opsworks (C0ACLSLFXAR)
**Status: DISABLED — awaiting cutover from Clio**

Scan `api-logs/*/YYYY-MM-DD.jsonl` for yesterday. Summarize writes by system. EXCLUDE Stripe (goes to #finance_muso). Post even if zero writes.

---

## Daily PR Code Review — Production Risk → #clio_devops_ops (C03DR6BGN2W)
**Status: DISABLED — awaiting cutover from Clio**

Cron: `daily-pr-review` (daily, 7:00 AM PST). Pull all PRs merged in last 24h across primary repos (core-backend, platform-data-processing, industry-data-processing, analytics-worker, devops, web-credits, mobile). For each PR: fetch the diff, analyze for production risks — OOM, memory leaks, scaling failures, connection exhaustion, concurrency bugs, data integrity risks, error swallowing. Post summary to C03DR6BGN2W (top-level header, threaded per-PR details). Focus on *problems the changes could create*, not style or nits. Added Mar 13, 2026 per Aaron.

---

## Memory & Process Health (every heartbeat)
**Status: DISABLED — awaiting cutover from Clio**

Check node RSS: `ps aux | grep '[n]ode' | grep -v Visual`. >400MB=WARNING, >800MB=CRITICAL (DM Aaron). Log to `memory/memory-monitor.log`.
