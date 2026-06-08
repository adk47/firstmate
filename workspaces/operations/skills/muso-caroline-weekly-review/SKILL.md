# muso-caroline-weekly-review

Daily pulse review of Caroline's Intercom conversations over a rolling ~30h window. Runs every day at 09:00 Europe/Rome via the operations cron. Returns a glanceable scored review as the final assistant message; the cron runner delivers it to `#cs_chats` (`C0ANM0PN9L5`). Grades voice + leak audit (A), tool/escalation hygiene (B), and customer sentiment (D). KB-gap detection and auto-PR are deferred to the separate weekly KB roll-up (sub-project 2) and are NOT run here.

> **Directory-name note:** this skill lives in `muso-caroline-weekly-review/` for historical reasons — renaming a workspace skill dir deletes tracked files and trips the deploy deletion gate. The job is daily; only the directory name is legacy. User-facing names (cron label `caroline-daily-review`, the Slack headline) all say daily.

## When to use

Invoked exclusively by the `caroline-daily-review` cron entry in `cron-jobs.json` (job id `03695380-8cee-4305-bedd-96dfbd3fbb18`). Slack delivery is routed by the cron entry's `delivery.to` field; the skill itself never picks a channel. To shadow-rollout: land the change with `enabled: false` in `cron-jobs.json`, deploy, fire once against a shadow `delivery.to` via `openclaw --profile main cron run 03695380-8cee-4305-bedd-96dfbd3fbb18`, verify the new format, then flip `enabled: true` + restore the live `delivery.to` in a separate one-line PR.

## Hard rules

- **Never post to Slack directly.** Return the review text as the final assistant message. The cron runner delivers it. Double-posting is a regression.
- **The daily run never edits files or opens PRs.** It only fetches, grades, and returns text.
- **No em-dashes in the output.** This is Caroline's voice rule, enforced mechanically at runtime: the final digest is piped through `scripts/redact-output.sh`, which normalizes any em/en-dash to a hyphen (and re-scrubs PII the grader may have reintroduced).
- **The header contract is enforced, not requested.** The final digest is piped through `scripts/assert-digest-contract.sh`, which fails the run if line 1 lacks the `P0 / P1 / P2` triplet + conversation count or line 2 lacks the Voice/Tools/Sentiment scores. Do not bypass it.
- _Parked for the weekly KB roll-up (SP2), unused by the daily path: the auto-PR step, its `workspaces/support/reference/*.md` restriction, and the cited-conversation_id evidence check in `validate-clusters.sh`._
- **Dimension B (tool usage) is skipped if `ctx.conversationId` is not plumbed through openclaw tool ctx.** Verified by `scripts/preflight.sh`. Do not fabricate correlation.
- **Reasoning-leak escalations are cited from the guard log, not the fetch.** An ESCALATED conv had its reply suppressed and is therefore ABSENT from `conversations.jsonl`; citing its id (from `audit.jsonl`) is expected, not an evidence violation. "0 guard-log lines" is NOT "0 leaks" — always pair it with the source-2 shipped-reply scan.

## Workflow

### Phase 0 — Preflight

**Source** `scripts/preflight.sh` (do not run as a subprocess — exports must survive into the rest of the pipeline). Run the entire pipeline (preflight -> fetch -> grade -> output) in a SINGLE shell session, so the exported `WORKDIR`, `CAROLINE_BOT_ADMIN_ID`, and `CV_TOOL_CTX_CONVERSATION_ID` are visible to all later scripts.

On preflight failure, return a "preflight failed: <reason>" message and stop. Do not attempt grading.

Preflight resolves `botAdminId` from the intercom plugin config and exports `CAROLINE_BOT_ADMIN_ID`, `WORKDIR`, `CV_TOOL_CTX_CONVERSATION_ID` (`available` or `unavailable`), and `CAROLINE_REASONING_LEAK_SOURCE` (`journalctl` | `syslog` | `none` — the guard-log read path; never fails preflight, but a degraded source must be surfaced in the digest). The fetch always does a broad `updated_at` pull + Caroline-author post-filter (no `admin_assignee_id` server-side filter — that dropped reassigned/escalated conversations), capped at the 200 most-recent conversations.

At the very end of the pipeline (success OR failure), the agent MUST `rm -rf "$WORKDIR"` to scrub the redacted customer transcripts from disk. (`preflight.sh` also installs an `INT`/`TERM` trap so an interrupted or timed-out run cleans `$WORKDIR` mechanically; the explicit `rm -rf` covers the normal-completion path, which the trap deliberately does not, so grading and Phase-3 validation can still read the data.)

### Phase 1 — Fetch (deterministic)

```bash
scripts/fetch-conversations.sh   # writes ${WORKDIR}/conversations.jsonl
scripts/fetch-audit.sh           # writes ${WORKDIR}/audit.jsonl  (leak + reasoning_leak guard lines)
scripts/redact.sh "${WORKDIR}/conversations.jsonl" "${WORKDIR}/conversations.redacted.jsonl"  # required args: <input> <output>
scripts/scan-shipped-leaks.sh    # writes ${WORKDIR}/shipped-leaks.jsonl  (Dim-E source 2; reads the redacted file, so run AFTER redact.sh)
scripts/scan-voice.sh            # writes ${WORKDIR}/voice-scan.jsonl (per-hit evidence) + ${WORKDIR}/voice-summary.txt (the aggregate the grader reads); Dim-A em-dash + phrase-blacklist scan; reads the redacted file, so run AFTER redact.sh
scripts/scan-sentiment.sh        # writes ${WORKDIR}/sentiment-scan.jsonl (per-hit evidence) + ${WORKDIR}/sentiment-summary.txt (the aggregate the grader reads); Dim-D explicit-frustration scan over CUSTOMER parts; reads the redacted file, so run AFTER redact.sh
scripts/scan-tools.sh            # writes ${WORKDIR}/tools-scan.jsonl (per-hit evidence) + ${WORKDIR}/tools-summary.txt (the aggregate the grader reads); Dim-B regression-watch (Caroline punting to email/contact support). Reads the RAW ${WORKDIR}/conversations.jsonl, NOT the redacted file — redact.sh scrubs support@muso.ai to <email>, so the rubric regex only matches pre-redaction; emits conv+marker only (no PII sample). Run AFTER fetch-conversations.sh
scripts/check-escalated.sh       # writes ${WORKDIR}/escalated-status.jsonl  (reads audit.jsonl, so run AFTER fetch-audit.sh)
```

### Phase 2 — Grade (LLM)

Read `references/grading-rubric.md`. Read `${WORKDIR}/conversations.redacted.jsonl` and `${WORKDIR}/audit.jsonl`. Produce structured findings for dimensions A (voice + leak), B (tools), D (sentiment), and E (reasoning-leak / guard health). For A, read `${WORKDIR}/voice-summary.txt` (the deterministic aggregate `scan-voice.sh` precomputes: per-marker tell totals, distinct-conv counts, top repeat convs, and the blacklist tally) and use its numbers VERBATIM in the digest. For D (sentiment), read `${WORKDIR}/sentiment-summary.txt` (the aggregate `scan-sentiment.sh` precomputes: `frustrated-convs` count, total `frustration-hits`, and the top frustrated convs with a sample) and use its numbers VERBATIM — `frustrated-convs` IS the Dimension D score input (`5 - frustrated-convs`, floor 0). For B (tools), read `${WORKDIR}/tools-summary.txt` (the aggregate `scan-tools.sh` precomputes for the rubric's regression watch: `regression-convs` — each a P0 — plus the by-marker tally and top conv ids) and use it VERBATIM; the remaining Dimension-B checks (`profile_status` coverage, `create_ticket` actionType/tier, refund 3-gate) are NOT mechanizable regexes — derive them from `${WORKDIR}/audit.jsonl` and your own reasoning. Do NOT re-derive the regression regex yourself: `scan-tools.sh` scans the RAW conversations because `redact.sh` rewrites `support@muso.ai` to `<email>`, so running `test("email support@muso\\.ai")` over `conversations.redacted.jsonl` yourself scores a silent FALSE CLEAN. Do NOT run `jq`/`awk`/`group_by` over ANY of the precomputed per-hit files (`${WORKDIR}/voice-scan.jsonl`, `${WORKDIR}/sentiment-scan.jsonl`, `${WORKDIR}/tools-scan.jsonl`, `${WORKDIR}/shipped-leaks.jsonl`) yourself — those are per-hit evidence for drill-down only (cite a `conv` id from one when you need an example), and hand-aggregating them has aborted the whole run twice (a `group_by` without `-s` threw "Cannot index string with string" on 2026-06-04; a hand-rolled sentiment `test(...)` jq aborted the 2026-06-08 run with `finalLen=0`, nothing delivered). Read the `*-summary.txt` aggregates instead. For E, additionally read `${WORKDIR}/shipped-leaks.jsonl` (source 2: guard-missed) and `${WORKDIR}/escalated-status.jsonl` (which escalations a human has answered), and apply the rubric's two-source no-conflation rule: a source-2 hit is a P0 even when source 1 is empty. Do NOT cluster KB gaps or invoke `scripts/cluster-questions.sh` / `scripts/open-kb-pr.sh` from the daily run — that is the weekly KB roll-up's job (SP2).

### Phase 3 — Output

1. Assemble the glanceable digest following the template in `references/grading-rubric.md` (header contract + collapse-clean rules).
2. Pipe it through `scripts/redact-output.sh` then `scripts/assert-digest-contract.sh`, and emit the result as the final assistant message:

   ```bash
   printf '%s' "$review_text" | scripts/redact-output.sh | scripts/assert-digest-contract.sh
   ```

   If `assert-digest-contract.sh` exits non-zero, the header contract was not met: fix the assembly and re-run. Never emit an unguarded digest.

3. **A recovered hiccup must NOT abort the run (deliver what you have).** The grading inputs are precomputed by the Phase-1 scripts precisely so Phase 2/3 needs no fragile ad-hoc shell. If you nonetheless run any one-off command and it errors, recover and continue to assembly — never let a single non-zero sub-exit end the run with nothing delivered. OpenClaw marks the whole run failed on any trailing tool error and suppresses the `#cs_chats` post (this is how the 2026-06-08 pulse was lost: `finalLen=0`, `delivered=false`). If a required input is genuinely unavailable after one retry, still emit a digest that names the degraded source (the contract enforces header/scores/guard), so the reviewer gets a marked-degraded pulse rather than silence.

## Environment

- `MUSOAI_INTERCOM_TOKEN` — required.
- `CAROLINE_WINDOW_HOURS` — rolling window for BOTH fetch scripts (`fetch-conversations.sh` and `fetch-audit.sh`). Default `30` (the daily pulse); leaving it unset is correct for the daily cron. The weekly KB roll-up (SP2) must set it INLINE at invocation (`CAROLINE_WINDOW_HOURS=168 scripts/fetch-conversations.sh`), NOT via a gateway-wide env — `cron-jobs.json` has no per-job env field, and a gateway-wide value would force both Caroline jobs to the same window.
- `OPS_CAROLINE_REVIEW_PR_OPEN` — parked for the weekly KB roll-up (SP2); the daily path opens no PRs and ignores it.
- `CAROLINE_REASONING_LEAK_SOURCE` — set by `preflight.sh` (`journalctl` | `syslog` | `none`); `fetch-audit.sh` reads the guard log from whichever resolved. Not set by hand.
- `CAROLINE_SYSLOG_PATH` — syslog file for the `syslog` fallback (default `/var/log/syslog`); override only in tests.

## References

- `references/grading-rubric.md` — dimension (A/B/D) definitions, scoring, severity, glanceable Slack template + header contract.
- `references/pr-template.md` — PR body template (parked for the weekly KB roll-up, SP2).
