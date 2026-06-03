# muso-caroline-weekly-review

Weekly review of Caroline's Intercom conversations. Runs every Monday 09:00 Europe/Rome via the operations cron. Returns a scored review as the final assistant message; the cron runner delivers it to `#cs_chats` (`C0ANM0PN9L5`). Optionally opens ONE PR against `workspaces/support/reference/*.md` when a KB gap repeats across ≥3 unique customers.

## When to use

Invoked exclusively by the `caroline-weekly-review` cron entry in `cron-jobs.json`. Slack delivery is routed by the cron entry's `delivery.to` field; the skill itself never picks a channel. To shadow-rollout, temporarily edit `delivery.to` in `cron-jobs.json` to your shadow channel ID, deploy, fire once via `openclaw cron run caroline-weekly-review --once`, then revert before merging the enable PR.

## Hard rules

- **Never post to Slack directly.** Return the review text as the final assistant message. The cron runner delivers it. Double-posting is a regression.
- **Never edit `SOUL.md`, `TOOLS.md`, or `skills/*/SKILL.md`.** Auto-PR is restricted to `workspaces/support/reference/[^/]+\.md$`, enforced mechanically in `validate-clusters.sh`.
- **No em-dashes anywhere.** The repo pre-commit hook blocks them; this skill blocks them earlier in `validate-clusters.sh`.
- **PR requires evidence.** Every cited conversation_id must exist in the fetched data, validated by `validate-clusters.sh`.
- **Dimension B (tool usage) is skipped if `ctx.conversationId` is not plumbed through openclaw tool ctx.** Verified by `scripts/preflight.sh`. Do not fabricate correlation.

## Workflow

### Phase 0 — Preflight

**Source** `scripts/preflight.sh` (do not run as a subprocess — exports must survive into the rest of the pipeline). Run the entire pipeline (preflight -> fetch -> grade -> output) in a SINGLE shell session, so the exported `WORKDIR`, `CAROLINE_BOT_ADMIN_ID`, and `CV_TOOL_CTX_CONVERSATION_ID` are visible to all later scripts.

On preflight failure, return a "preflight failed: <reason>" message and stop. Do not attempt grading.

Preflight resolves `botAdminId` from the intercom plugin config and exports `CAROLINE_BOT_ADMIN_ID`, `WORKDIR`, and `CV_TOOL_CTX_CONVERSATION_ID` (`available` or `unavailable`). The fetch always does a broad `updated_at` pull + Caroline-author post-filter (no `admin_assignee_id` server-side filter — that dropped reassigned/escalated conversations), capped at the 200 most-recent conversations.

At the very end of the pipeline (success OR failure), the agent MUST `rm -rf "$WORKDIR"` to scrub the redacted customer transcripts from disk. (`preflight.sh` also installs an `INT`/`TERM` trap so an interrupted or timed-out run cleans `$WORKDIR` mechanically; the explicit `rm -rf` covers the normal-completion path, which the trap deliberately does not, so grading and Phase-3 validation can still read the data.)

### Phase 1 — Fetch (deterministic)

```bash
scripts/fetch-conversations.sh   # writes ${WORKDIR}/conversations.jsonl
scripts/fetch-audit.sh           # writes ${WORKDIR}/audit.jsonl
scripts/redact.sh "${WORKDIR}/conversations.jsonl" "${WORKDIR}/conversations.redacted.jsonl"  # required args: <input> <output>
```

### Phase 2 — Grade (LLM)

Read `references/grading-rubric.md`. Read `${WORKDIR}/conversations.redacted.jsonl` and `${WORKDIR}/audit.jsonl`. Produce structured findings per dimension. Cluster KB-gap candidates by topic via `scripts/cluster-questions.sh`. For clusters with N≥3 unique contacts, draft a proposed insertion into a target `reference/*.md` file.

### Phase 3 — Output

1. Assemble the Slack review text following the template in `references/grading-rubric.md`.
2. If KB-gap clusters with N≥3 evidence exist, write the approved cluster set to `${WORKDIR}/approved-clusters.json` and run `scripts/open-kb-pr.sh ${WORKDIR}/approved-clusters.json ${WORKDIR}/conversations.jsonl`. The script is itself gated on `OPS_CAROLINE_REVIEW_PR_OPEN=1` — when unset it exits 0 with a skip message, and the Slack review can note "would-have-PRd". When the env is set and PR creation succeeds, append the PR URL to the Slack review.
3. Pipe the final Slack review text through `scripts/redact-output.sh` before emitting it as the final assistant message.

## Environment

- `MUSOAI_INTERCOM_TOKEN` — required.
- `OPS_CAROLINE_REVIEW_PR_OPEN` — mechanical opt-in for the auto-PR step. Default unset = skip `gh pr create`; the review still posts. Set to `1` in the gateway service env (e.g. `/etc/openclaw/main.env` on hydra) so the cron-spawned agent session inherits it. `cron-jobs.json` has no per-job env field — there's no point setting it there.

## References

- `references/grading-rubric.md` — dimension definitions, scoring, severity, Slack output template.
- `references/pr-template.md` — PR body template.
