# HEARTBEAT.md — CTO Agent

⛔ ALL AUTOMATIONS DISABLED — Running on Clio until cutover

### Daily PR Code Review — Production Risk
Schedule: daily 7:00 AM PST
Channel: #engineering
Pull all PRs merged in last 24h across primary repos (core-backend, platform-data-processing, industry-data-processing, analytics-worker, devops, web-credits, mobile). Analyze for production risks: OOM, memory leaks, scaling failures, connection exhaustion, concurrency bugs, data integrity risks.

### Commit Review — Critical Repos
Schedule: daily
Channel: #clio_devops
Scan last 24h commits. Flag schema changes, column adds/removes/renames, contract changes, import driver changes. Cross-reference removed/renamed columns.

### Industry Realtime Import Freshness
Schedule: daily
Check S3 checkpoint timestamps. Alert if any table checkpoint >8h stale.
