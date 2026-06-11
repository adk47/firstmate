# Caroline review: structured digest, Block Kit, themes, weekly roll-up

Date: 2026-06-11. Decision record for the upgrade of the Caroline daily pulse
(and the new weekly roll-up) requested by Nick: better visuals + a
cross-conversation "did multiple customers say the same thing" themes section.
Builds on `docs/2026-06-04-caroline-daily-review-design.md` (SP1); this lands
the deferred SP2 weekly as Slack-surface-only.

## What changed

Before: the Phase-2 LLM hand-assembled a plain-text digest, gated by
`assert-digest-contract.sh`, delivered by the cron runner's announce mode.

After: Phase 2 writes a **structured `digest.json`**
(`references/digest-schema.json`); everything downstream is deterministic
(`workspaces/operations/skills/muso-caroline-weekly-review/scripts/`):

```
publish-digest.sh digest.json conversations.jsonl audit.jsonl
  ├─ validate-digest.sh   schema + join-key honesty + anti-hallucination ids
  │                       + theme recompute via cluster-questions.sh
  ├─ redact-json.sh       PII re-scrub (shared lib/redact-core.sed)
  ├─ render-digest.py --text | redact-output.sh | linkify-convs.sh
  │                       | assert-digest-contract.sh     -> fallback text
  ├─ render-digest.py --blocks                            -> Block Kit payload
  └─ post-digest.sh       chat.postMessage as the operations ("Ops") bot
```

stdout of `publish-digest.sh` is always the final assistant message: a one-line
confirmation on success, or `🔴 ... FAILED` + the full plain-text fallback on a
Slack failure — the cron announce delivery (unchanged, → #cs_chats) then still
carries the digest. A Slack failure is converted inside the script so it can
never be the run's trailing tool error (the 2026-06-08 `finalLen=0` class).

## Key decisions

- **Posting identity**: `chat.postMessage` with the `operations` bot token from
  `/root/.openclaw-main/openclaw.json` — the identity that already posts the
  close-resolved summary to #cs_chats (`scripts/close-resolved-conversations.py`).
  NOT the devops `slack-notify.sh` account, NOT a webhook (none exists for
  #cs_chats). `ok:true` is parsed; HTTP 200 alone is not delivery proof.
- **LLM never authors headers/links/Block Kit.** Status emoji, P0 ping
  (`<@U0AL36NADEY>`), severity triplet, scores line, guard block, linkified
  conversation ids are all computed by `render-digest.py` from validated
  counts. Both render modes share one implementation so the Block Kit post and
  the announce fallback cannot drift.
- **Themes are gated mechanically.** The grader proposes
  `{category, label, summary, conversation_ids, unique_customers}`;
  `validate-digest.sh` hard-fails hallucinated conversation ids, recomputes
  `unique_customers` by `contact_id` dedupe (`cluster-questions.sh`), and drops
  themes under 2 recomputed unique customers. Weekly `kb_gap_candidates`
  require a recomputed >= 3 or the run fails; a daily digest carrying any fails.
- **Weekly roll-up = Slack surface only in v1.** `open-kb-pr.sh` /
  `validate-clusters.sh` stay parked; the digest footer says so. Cron
  `caroline-weekly-rollup` (Mon 10:00 Europe/Rome — an hour after the daily so
  the fetches never race) ships `enabled:false`.
- **Ping placement**: Slack `header` blocks are plain_text and don't render
  mentions, so a P0 day leads with a mention `section` and the payload
  notification `text` carries the ping for the push.

## Rollout

1. Merge + deploy (this PR): daily cron message now drives the new pipeline;
   weekly job present but disabled.
2. On node-8: one manual shadow fire of the daily
   (`CAROLINE_DIGEST_CHANNEL=<shadow> openclaw --profile main cron run
   03695380-8cee-4305-bedd-96dfbd3fbb18`), eyeball desktop + mobile rendering.
3. One manual shadow fire of the weekly the same way, then flip
   `enabled:true` in a one-line PR.

Rollback: revert the daily cron `payload.message` to the pre-PR text — the
legacy text path (`redact-output.sh | linkify-convs.sh |
assert-digest-contract.sh`) is untouched and `assert-digest-contract.sh` still
gates it.

## Tests

`workspaces/operations/skills/muso-caroline-weekly-review/scripts/tests/`:
new suites `validate-digest`, `redact-json`, `render-digest`, `build-blocks`,
`post-digest`, `publish-digest` (52 tests; curl PATH-stubbed, never touches
Slack). Full skill suite 220/220 green. CI runs the directory via the
bats-tests job in `pr-validate.yml`.
