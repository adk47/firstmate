# muso-caroline-weekly-review

Scored review of Caroline's Intercom conversations, posted to `#cs_chats` (`C0ANM0PN9L5`) as a Block Kit message by the Ops bot. Two modes off the same pipeline:

- **Daily pulse** (cron `caroline-daily-review`, 09:00 Europe/Rome, ~30h window): grades voice + leak audit (A), tool/escalation hygiene (B), customer sentiment (D), guard health (E), plus an informational **Themes** section (>=2 unique customers saying the same thing).
- **Weekly roll-up** (cron `caroline-weekly-rollup`, Mon 10:00 Europe/Rome, 168h window): same grade plus the full cross-conversation theme roll-up (recurring issues / questions / feature asks / escalation patterns) and **KB-gap candidates** (>=3 unique customers; auto-PR stays manual in v1 — surface candidates in Slack only).

The grader emits a structured `digest.json`; everything after that — validation, redaction, rendering (plain text AND Block Kit), Slack posting — is deterministic scripts. The cron's announce delivery carries the pipeline's final status text as a fail-loud fallback channel.

> **Directory-name note:** this skill lives in `muso-caroline-weekly-review/` for historical reasons — renaming a workspace skill dir deletes tracked files and trips the deploy deletion gate. User-facing names (cron labels, the Slack headline) say daily/weekly explicitly.

## When to use

Invoked exclusively by the `caroline-daily-review` and `caroline-weekly-rollup` cron entries in `cron-jobs.json`. The Block Kit post targets `#cs_chats` via `scripts/post-digest.sh`; the cron `delivery.to` only routes the pipeline's final status line (the fallback). To shadow-rollout a format change: export `CAROLINE_DIGEST_CHANNEL=<shadow channel id>` for one manual `openclaw --profile main cron run <job id>`, eyeball the rendering (desktop + mobile), then drop the override.

## Hard rules

- **Never post to Slack except via `scripts/publish-digest.sh`** (which calls `post-digest.sh` exactly once). Do not use the message tool, do not curl Slack by hand, do not also paste the digest into the final message on success — double-posting is a regression. The final assistant message is whatever `publish-digest.sh` printed, verbatim.
- **Never hand-author header lines, Slack links, or Block Kit JSON.** Phase 2 writes `digest.json` per `references/digest-schema.json`; `render-digest.py` computes the headline (status emoji, P0 ping, severity triplet, scores line) from the validated counts. Conversation ids are BARE 15-16 digit strings everywhere in `digest.json`.
- **The contract is enforced, not requested.** `validate-digest.sh` fails the run on schema violations, hallucinated conversation ids, a fabricated Tools score, or inflated theme counts (it recomputes `unique_customers` mechanically). If it exits non-zero: fix `digest.json` and re-run it. Never bypass it.
- **The daily run never edits files or opens PRs**, and a daily digest must have an empty `kb_gap_candidates` (enforced). The weekly run surfaces KB-gap candidates in Slack only — `open-kb-pr.sh` stays a manual, human-triggered step in v1.
- **No em-dashes in output text fields.** Enforced mechanically: `redact-json.sh` (and `redact-output.sh` on the fallback) normalizes em/en dashes to hyphens and re-scrubs PII the grader may have reintroduced.
- **Dimension B (tool usage) is skipped if `ctx.conversationId` is not plumbed through openclaw tool ctx.** Verified by `scripts/preflight.sh`; `validate-digest.sh` enforces `scores.tools == "skipped"` exactly when the prereq is unavailable. Do not fabricate correlation.
- **Reasoning-leak escalations are cited from the guard log, not the fetch.** An ESCALATED conv had its reply suppressed and is therefore ABSENT from `conversations.jsonl`; citing its id (from `audit.jsonl`) is expected — `guard.items[]` is the only place audit-sourced ids are legal. "0 guard-log lines" is NOT "0 leaks" — always pair it with the source-2 shipped-reply scan.

## Workflow

### Phase 0 — Preflight

**First, enter the skill directory** — every `scripts/…` path below is relative to it. Run this verbatim as the first line of the single shell session; do not improvise the path. This is a workspace-native skill (it is NOT mirrored into any openclaw managed-skills tier), so a guessed managed-skills location does not exist on disk, and a failed `cd` there is the single early tool error that makes openclaw mark the whole run failed and silently suppress the `#cs_chats` delivery — exactly how the 2026-06-08 07:00 pulse was lost.

```bash
cd /opt/hydra/workspaces/operations/skills/muso-caroline-weekly-review || { echo "preflight failed: skill dir not found"; exit 1; }
```

**Then, source** `scripts/preflight.sh` (do not run as a subprocess — exports must survive into the rest of the pipeline). Run the entire pipeline (preflight -> fetch -> grade -> publish) in a SINGLE shell session, so the exported `WORKDIR`, `CAROLINE_BOT_ADMIN_ID`, and `CV_TOOL_CTX_CONVERSATION_ID` are visible to all later scripts.

On preflight failure, return a "preflight failed: <reason>" message and stop. Do not attempt grading.

Preflight resolves `botAdminId` from the intercom plugin config and exports `CAROLINE_BOT_ADMIN_ID`, `WORKDIR`, `CV_TOOL_CTX_CONVERSATION_ID` (`available` or `unavailable`), and `CAROLINE_REASONING_LEAK_SOURCE` (`journalctl` | `syslog` | `none` — the guard-log read path; never fails preflight, but a degraded source must be surfaced in the digest). The fetch always does a broad `updated_at` pull + Caroline-author post-filter (no `admin_assignee_id` server-side filter — that dropped reassigned/escalated conversations), capped at the 200 most-recent conversations. If the fetch reports it hit the cap, add a `degraded` note ("conv fetch hit the 200 cap - window under-sampled") — this matters on the 168h weekly window.

At the very end of the pipeline (success OR failure), the agent MUST `rm -rf "$WORKDIR"` to scrub the redacted customer transcripts from disk. (`preflight.sh` also installs an `INT`/`TERM` trap so an interrupted or timed-out run cleans `$WORKDIR` mechanically; the explicit `rm -rf` covers the normal-completion path, which the trap deliberately does not, so grading and Phase-3 validation can still read the data.)

### Phase 1 — Fetch (deterministic)

Daily runs use the script-default window (do NOT pass one). Weekly runs set the window INLINE on both fetch invocations (`CAROLINE_WINDOW_HOURS=168 scripts/fetch-conversations.sh`, same for `fetch-audit.sh`) — never gateway-wide.

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

### Phase 2 — Grade (LLM) -> write `${WORKDIR}/digest.json`

Read `references/grading-rubric.md` and `references/digest-schema.json`. Read `${WORKDIR}/conversations.redacted.jsonl` and `${WORKDIR}/audit.jsonl`. Produce the structured digest — dimensions A (voice + leak), B (tools), D (sentiment), E (guard) become `scores` + `findings` + `guard` entries; cross-conversation recurrence becomes `themes` (and, weekly only, `kb_gap_candidates`).

For A, read `${WORKDIR}/voice-summary.txt` (the deterministic aggregate `scan-voice.sh` precomputes: per-marker tell totals, distinct-conv counts, top repeat convs, and the blacklist tally) and use its numbers VERBATIM. For the leak-audit half of A, each `email-leak` line in `audit.jsonl` carries `leak_class`: grade `internal` (a non-support `@muso.ai` employee address) and `unknown` (an unparseable email-leak line — fail closed) as **P0**, and `external` (a customer/third-party address the sanitizer already redacted before send) as **P2**, per the rubric's severity ladder; `tool-leak` lines stay P0. For D, read `${WORKDIR}/sentiment-summary.txt` and use its numbers VERBATIM — `frustrated-convs` IS the Dimension D score input (`5 - frustrated-convs`, floor 0). For B, read `${WORKDIR}/tools-summary.txt` VERBATIM (`regression-convs` — each a P0); the remaining Dimension-B checks (`profile_status` coverage, `create_ticket` actionType/tier, refund 3-gate) are NOT mechanizable regexes — derive them from `${WORKDIR}/audit.jsonl` and your own reasoning. Do NOT re-derive the regression regex yourself: `scan-tools.sh` scans the RAW conversations because `redact.sh` rewrites `support@muso.ai` to `<email>`, so running `test("email support@muso\\.ai")` over `conversations.redacted.jsonl` yourself scores a silent FALSE CLEAN. Do NOT run `jq`/`awk`/`group_by` over ANY of the precomputed per-hit files (`voice-scan.jsonl`, `sentiment-scan.jsonl`, `tools-scan.jsonl`, `shipped-leaks.jsonl`) yourself — those are per-hit evidence for drill-down only (cite a `conv` id from one when you need an example); hand-aggregating them has aborted the whole run twice. For E, additionally read `${WORKDIR}/shipped-leaks.jsonl` (source 2: guard-missed) and `${WORKDIR}/escalated-status.jsonl` (which escalations a human has answered), and apply the rubric's two-source no-conflation rule: a source-2 hit is a P0 even when source 1 is empty.

**Themes pass** (both modes): read the customer parts in `conversations.redacted.jsonl` and cluster what MULTIPLE customers are saying into `themes` — `category` one of `issue` (same bug/complaint), `question` (same how-do-I), `feature_request` (same capability ask), `escalation_pattern` (same reason convs end up with a human). Cite every member conversation id; set `unique_customers` to your count knowing `validate-digest.sh` recomputes it by `contact_id` dedupe and drops themes below 2 — do not pad a cluster with loosely-related convs to inflate it. Weekly only: promote a theme to `kb_gap_candidates` when >=3 unique customers asked something the KB does not answer, adding `proposed_kb_note` (the text a human would paste into `workspaces/support/reference/*.md`).

Write the result as JSON to `${WORKDIR}/digest.json` (e.g. via a heredoc to `cat > "${WORKDIR}/digest.json"`). Plain prose in text fields, bare conversation ids, no URLs, no markdown links.

### Phase 3 — Publish (deterministic)

One call runs the whole tail — validate -> redact -> render fallback text (through the legacy `redact-output.sh | linkify-convs.sh | assert-digest-contract.sh` gates) -> build Block Kit -> post as the Ops bot:

```bash
CAROLINE_EXPECTED_KIND=daily scripts/publish-digest.sh "${WORKDIR}/digest.json" "${WORKDIR}/conversations.jsonl" "${WORKDIR}/audit.jsonl"
```

(`CAROLINE_EXPECTED_KIND=weekly` on the weekly run.) Behavior:

- **Exit non-zero** = the digest failed validation; stderr names every violation. Fix `${WORKDIR}/digest.json` and re-run `publish-digest.sh` (at most a couple of iterations; the errors are precise). Nothing was posted.
- **Exit 0** = done. stdout is the final assistant message — emit it VERBATIM and emit nothing else. On a successful post it is a one-line confirmation (the announce delivery turns it into a delivery heartbeat in `#cs_chats`); on a Slack post failure it is a loud alert + the full plain-text fallback digest, which announce then delivers, so the review reaches `#cs_chats` either way. A Slack failure is already handled INSIDE the script — do not retry the post yourself.

**A recovered hiccup must NOT abort the run (deliver what you have).** The grading inputs are precomputed by the Phase-1 scripts precisely so Phase 2/3 needs no fragile ad-hoc shell. If you nonetheless run any one-off command and it errors, recover and continue — never let a single non-zero sub-exit end the run with nothing delivered. OpenClaw marks the whole run failed on any trailing tool error and suppresses delivery (this is how the 2026-06-08 pulse was lost: `finalLen=0`, `delivered=false`). If a required input is genuinely unavailable after one retry, still build a digest that names the degraded source in `degraded[]` — the reviewer gets a marked-degraded pulse rather than silence.

## Environment

- `MUSOAI_INTERCOM_TOKEN` — required.
- `CAROLINE_WINDOW_HOURS` — rolling window for BOTH fetch scripts. Default `30` (the daily pulse); leaving it unset is correct for the daily cron. The weekly roll-up sets it INLINE at invocation (`CAROLINE_WINDOW_HOURS=168 scripts/fetch-conversations.sh`), NOT via a gateway-wide env — `cron-jobs.json` has no per-job env field, and a gateway-wide value would force both Caroline jobs to the same window.
- `CAROLINE_EXPECTED_KIND` — `daily` | `weekly`; set inline on the `publish-digest.sh` call so a digest graded in the wrong mode cannot ship.
- `CAROLINE_DIGEST_CHANNEL` — Block Kit target channel override (default `C0ANM0PN9L5` #cs_chats). Shadow-rollout knob only; never set in the live crons.
- `SLACK_ACCOUNT` / `MUSO_BIN` / `MUSO_SLACK_ENV_FILE` — `post-digest.sh` send identity and muso CLI seam (defaults: `operations` bot, `muso`, `/etc/openclaw/main.env` for the `MUSO_SLACK_BOT_TOKEN_*` vars). Test overrides only.
- `OPS_CAROLINE_REVIEW_PR_OPEN` — parked; no mode opens PRs and both ignore it.
- `CAROLINE_REASONING_LEAK_SOURCE` — set by `preflight.sh` (`journalctl` | `syslog` | `none`); `fetch-audit.sh` reads the guard log from whichever resolved. Not set by hand.
- `CAROLINE_SYSLOG_PATH` — syslog file for the `syslog` fallback (default `/var/log/syslog`); override only in tests.

## References

- `references/grading-rubric.md` — dimension (A/B/D/E) definitions, scoring, severity, themes guidance.
- `references/digest-schema.json` — the machine contract for `${WORKDIR}/digest.json` (what `validate-digest.sh` enforces).
- `references/pr-template.md` — PR body template (parked; KB auto-PR stays manual in v1).
