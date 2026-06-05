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
scripts/scan-voice.sh            # writes ${WORKDIR}/voice-scan.jsonl  (Dim-A em-dash + phrase-blacklist scan; reads the redacted file, so run AFTER redact.sh)
scripts/check-escalated.sh       # writes ${WORKDIR}/escalated-status.jsonl  (reads audit.jsonl, so run AFTER fetch-audit.sh)
```

### Phase 2 — Grade (LLM)

Read `references/grading-rubric.md`. Read `${WORKDIR}/conversations.redacted.jsonl` and `${WORKDIR}/audit.jsonl`. Produce structured findings for dimensions A (voice + leak), B (tools), D (sentiment), and E (reasoning-leak / guard health). For A, read `${WORKDIR}/voice-scan.jsonl` (the deterministic em-dash + phrase-blacklist scan) and COUNT its rows — do NOT compose your own dash/blacklist scan (a hand-rolled scan under the pipeline's `set -euo pipefail` has aborted the whole run). For E, additionally read `${WORKDIR}/shipped-leaks.jsonl` (source 2: guard-missed) and `${WORKDIR}/escalated-status.jsonl` (which escalations a human has answered), and apply the rubric's two-source no-conflation rule: a source-2 hit is a P0 even when source 1 is empty. Do NOT cluster KB gaps or invoke `scripts/cluster-questions.sh` / `scripts/open-kb-pr.sh` from the daily run — that is the weekly KB roll-up's job (SP2).

### Phase 3 — Output

1. Assemble the glanceable digest following the template in `references/grading-rubric.md` (header contract + collapse-clean rules).
2. Pipe it through `scripts/redact-output.sh` then `scripts/assert-digest-contract.sh`, and emit the result as the final assistant message:

   ```bash
   printf '%s' "$review_text" | scripts/redact-output.sh | scripts/assert-digest-contract.sh
   ```

   If `assert-digest-contract.sh` exits non-zero, the header contract was not met: fix the assembly and re-run. Never emit an unguarded digest.

## Environment

- `MUSOAI_INTERCOM_TOKEN` — required.
- `CAROLINE_WINDOW_HOURS` — rolling window for BOTH fetch scripts (`fetch-conversations.sh` and `fetch-audit.sh`). Default `30` (the daily pulse); leaving it unset is correct for the daily cron. The weekly KB roll-up (SP2) must set it INLINE at invocation (`CAROLINE_WINDOW_HOURS=168 scripts/fetch-conversations.sh`), NOT via a gateway-wide env — `cron-jobs.json` has no per-job env field, and a gateway-wide value would force both Caroline jobs to the same window.
- `OPS_CAROLINE_REVIEW_PR_OPEN` — parked for the weekly KB roll-up (SP2); the daily path opens no PRs and ignores it.
- `CAROLINE_REASONING_LEAK_SOURCE` — set by `preflight.sh` (`journalctl` | `syslog` | `none`); `fetch-audit.sh` reads the guard log from whichever resolved. Not set by hand.
- `CAROLINE_SYSLOG_PATH` — syslog file for the `syslog` fallback (default `/var/log/syslog`); override only in tests.

## References

- `references/grading-rubric.md` — dimension (A/B/D) definitions, scoring, severity, glanceable Slack template + header contract.
- `references/pr-template.md` — PR body template (parked for the weekly KB roll-up, SP2).
