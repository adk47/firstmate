# support@muso.ai email triage — rollout & follow-ups

Status as of 2026-06-05. Built on branch `chore/does-caroline-have-access-to`.
**v1 = TRIAGE / NOTIFY ONLY — nothing is ever sent to a customer.**

- **Skill**: `workspaces/operations/skills/muso-support-email-triage/`
  (preflight → gog fetch → LLM classify → deterministic digest)
- **Cron**: `support-email-triage-hourly` in `cron-jobs.json`
  (id `62f2c090-39a7-469e-bcdf-90f28d0178aa`, agent `operations`, `isolated`,
  `0 * * * *` Europe/Rome, **`enabled: false`**, delivers to `#cs_chats`
  `C0ANM0PN9L5`).

There is **no "omnitoken"** for @muso.ai mail — access is the per-user `gog` CLI,
and `support@` is **not yet authenticated**. See the access topology in the memory
note `reference_hydra_gmail_gog_access_topology`.

---

## 0. BLOCKER — provision the mailbox (must happen first; human step)

The whole thing is inert until `support@` is authed in gog. On node-8:

- [ ] `gog auth add support@muso.ai`  ← interactive browser OAuth; needs the
      support@ Google login. Do NOT touch the existing 4 accounts.
- [ ] Verify: `gog gmail messages search "in:inbox newer_than:1d" --account support@muso.ai --json --include-body`
- [ ] (Durability) add `support@muso.ai` to the `weekly-google-token-refresh`
      cron's account list so the refresh token does not hit the ~6-month expiry.

Until this is done, preflight stops cleanly with
`preflight failed: support@muso.ai not authenticated in gog` — safe to deploy.

## 1. Rollout (after the mailbox is authed)

- [ ] Merge this PR → deploy. Skill + cron land **disabled**; zero behavior change.
- [ ] Shadow proof run on node-8:
      `openclaw --profile main cron run 62f2c090-39a7-469e-bcdf-90f28d0178aa`
      Confirm: a `#cs_chats` post with correct counts, working Gmail links, a
      sensible Caroline-can-handle vs needs-human split, and that **no email,
      draft, label change, or ticket** was created. (If the inbox was quiet it
      prints `NO_REPLY` — fire it when there is recent mail, or temporarily widen
      `SUPPORT_TRIAGE_WINDOW_MIN`.)
- [ ] If good, flip `enabled: true` in a one-line PR. Watch the first few fires in
      `cron/runs/*.jsonl`.
- [ ] Tune on real traffic: window (65 min), `thinking` level (low), classification
      quality. If hourly is noisy, point `delivery.to` at a quieter channel for the
      first day.

## 2. Known limitations / decisions (v1)

- Triage only — never sends. The hourly digest **is** the "notify someone in
  #cs_chats." One post/hour, no per-email @mention pings (avoids channel spam).
- Counts/subjects/senders/links are deterministic (from the gog fetch); only
  `description`/`verdict`/`reason` are LLM-authored. `format-digest.sh` **fails
  loud** if the verdicts do not reconcile with the fetched threads.
- Deduped by thread (one line per thread).
- Misclassification is low-stakes in v1: every thread is listed with a link
  regardless of bucket, so a human reading the digest sees them all.

## 3. Phase 2+ — actually answering email (separate project)

To have Caroline **send** replies (the chosen end-state "Gmail channel for Caroline
on edge"):

- [ ] Gmail channel/poller on the **edge** gateway that routes `support@` threads
      to Caroline as conversations. This revives the deleted `openclaw-gmail`
      plugin path (removed 2026-05-20, issue #329) and **reverses edge isolation**
      — needs a security review.
- [ ] **Gmail-side outbound sanitizer** — the email equivalent of
      `plugins/intercom/src/sanitize-email.ts` + `sanitize-reasoning-leak.ts`.
      Those are Intercom-channel-bound and do **not** cover Gmail; without this,
      Caroline's email replies have no leak guard.
- [ ] Reply-autonomy ladder: draft-for-approval (Gmail drafts + #cs_chats approve)
      → auto-send when confident. Ship flag-off, shadow first.
- [ ] Decide the send identity (`support@` via `gog`, vs an Intercom-style admin
      identity).

## References

- Plan: `~/.claude/plans/does-caroline-have-access-breezy-thompson.md`
- Pattern precedents: the `caroline-daily-review` cron + `muso-caroline-weekly-review`
  skill (operations → #cs_chats); `scripts/close-resolved-conversations.py`
  (Slack mrkdwn `<url|text>` + `_slack_escape`).
