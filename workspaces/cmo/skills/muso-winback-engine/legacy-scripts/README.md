# Legacy Win Back Scripts

These scripts were inherited from the previous `muso-winback-pro` skill. They
are NOT part of the current production flow.

## Status

**LEGACY, NEEDS REVIEW BEFORE USE.** These scripts predate the rebuild and
reference old config (channels, cadence, sheet structure). Do not run them
without first verifying:

1. They point to `#win-back-alerts`, not `#clio_x_fede` or `#clio_analyst`
2. They use `$GHL_WINBACK_API_KEY`, not a hardcoded key or `$GHL_API_KEY`
3. They use the cadence Day 7 / Day 45 / Day 90 (not the old 7/14/21)
4. They handle the new sheet structure (`pro_churned_all`, `high_value_churn`)
5. They run the Pre Send Stripe Check on every send
6. They CC `support@muso.ai` and do NOT BCC
7. They strip em dashes from any generated copy

## Files

| Script | Original Purpose |
|--------|------------------|
| `daily-winback.sh` | Main entry: pull batch, draft, send, sync GHL |
| `winback_engine.py` | Core logic: prioritization, drafting, sending, tracking |
| `qa_checklist.py` | Multi pass QA (structural, content, cross reference) |
| `plan_batch.py` | Midnight planner: select next 120, mark Next Up |
| `reply_scanner.py` | Scan Gmail for replies, post to Slack, update GHL + sheet |
| `sanity_check.py` | Cross check sheet vs GHL vs Gmail, flag drift |
| `check-winback-replies.sh` | Wrapper for reply scan (from old muso-winback-engine) |

## Why Keep Them

The new `muso-winback-*` subskills define the WORKFLOW but do not include
implementation code. These legacy scripts contain real Python and bash logic
that may be useful as a starting point when wiring up cron jobs.

If you decide to use them:
1. Read the script
2. Update any hardcoded config (channels, sheet IDs, API keys, etc) to match the new shared config
3. Strip em dashes from any string literals in the code
4. Test in dry run mode before any live send
5. If you make significant changes, copy the modified version into the right subskill's directory and remove the legacy copy

## Decision

Either:
- **A**: Modernize one or more of these scripts and use them as the cron implementation for `muso-winback-sender`, `muso-winback-followup`, `muso-winback-reply-scanner`, etc.
- **B**: Rewrite the cron implementations from scratch using the SKILL.md specs
- **C**: Delete this directory entirely if you decide they are not worth keeping

Nick to decide once campaigns are ready to launch.

## History

- 2026-04-09: scripts moved here from `muso-winback-pro/scripts/` and `muso-winback-engine/scripts/` during win back rebuild
