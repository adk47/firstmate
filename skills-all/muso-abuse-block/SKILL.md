---
name: muso-abuse-block
description: |
  Add (or remove) a person on the abuse-block list — stop an abusive scraper or
  customer from generating support work. Tags their Intercom conversations (and
  contact) with the `abuse-block` tag the edge gateway filters on, so Caroline
  never replies, never escalates, and never opens a ClickUp ticket for them.

  Use when: an abusive/scraper contact is manipulating support (e.g. trying to
  get an IP unblocked or an API key issued), you need to silence support for a
  known bad actor, "shadow-ban" someone in Intercom, or reverse a block.

  Triggers: "abuse-block", "block this customer", "shadow ban", "stop replying
  to", "scraper in support", "abusive contact", "unblock" (with --remove)
allowed-tools:
  - exec
depends-on:
  - muso-intercom
compatibility: |
  Requires MUSOAI_INTERCOM_TOKEN in env (ops/main agent has it; for ad-hoc SSH
  runs `source /etc/openclaw/main.env` first). Ops (main) agent only — Caroline
  /edge is exec-denied and could not self-block anyway.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/hydra"
---

# Muso Ops — Abuse-Block List

Silence support for an abusive contact and stop them generating tickets.

## What this does (mechanism)

The edge gateway's intercom plugin filters customer messages whose conversation
carries a tag listed in `openclaw-edge.json`
`channels.intercom.accounts.default.blockedChannelTags` (which includes
`abuse-block`). On a match the handler (`plugins/intercom/src/handler.ts`)
returns `filtered` **before dispatch** — so Caroline never replies, never
escalates, and never calls `create_ticket` for that conversation.

This script applies that `abuse-block` tag to a contact's conversations (and to
the contact record), so adding someone "to the abuse-block list" = tagging them.

**Scope — this only stops SUPPORT engagement.** It does NOT revoke API keys,
block IPs, or stop scraping — those are API-key / core-backend / Cloudflare
concerns, handled separately. Blocking here just denies the person a support
channel to manipulate.

## Access control

- **`--requester` is REQUIRED** on every run (slack id or email). It is recorded
  in the shadow log as the audit trail — this is who authorized the block.
- Ops (main) agent runs this under human direction. Confirm the target identity
  from the dry-run output (name + email + conversation count) before `--apply`.

## Workflows

### 1. Preview the block (ALWAYS do this first)

```bash
python3 ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-abuse-block/scripts/abuse-block.py \
  --requester "$REQUESTER" --email <contact_email> --reason "<why>"
```

Dry-run is the default — it prints the contact(s) it resolved and the
conversations it WOULD tag, with no writes. Verify the name/email is really the
person you mean to block, then re-run with `--apply`.

### 2. Apply the block

```bash
python3 ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-abuse-block/scripts/abuse-block.py \
  --requester "$REQUESTER" --email <contact_email> --reason "<why>" --apply
```

Add `--close` to also close their open conversations (tidier — by default the
block only tags, leaving convs in the human inbox). Use `--contact-id <id>`
instead of `--email` when you already have the Intercom contact id.

### 3. Reverse a block (unblock)

```bash
python3 ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-abuse-block/scripts/abuse-block.py \
  --requester "$REQUESTER" --email <contact_email> --remove --apply
```

`--remove` detaches the `abuse-block` tag from the contact + their conversations.
It does NOT reopen closed conversations.

## Durability — covering NEW conversations

Tagging is **per-conversation**. It covers the contact's existing and reopened
threads (the blocked-tag check runs before the implicit-reopen logic). A
brand-NEW conversation the contact starts is not auto-tagged.

To close that gap, this script also tags the **contact** record. Pair it with an
**Intercom Workflow** (dashboard, no code) that auto-applies the `abuse-block`
tag to any conversation started by a contact already carrying the `abuse-block`
tag. Set that Workflow up once; then every future conversation is filtered on
arrival. (If Intercom Workflows can't express that condition, the fallback is a
per-email denylist in the intercom plugin — only build it if needed.)

## Audit

Every `--apply` run appends a JSON record (requester, reason, contacts,
conversations tagged/closed, mode) to `$ABUSE_BLOCK_LOG`
(default `/var/log/abuse-block.jsonl`, falls back to `/tmp`) — reversible record
of who blocked whom and when.

## Report results

Summarize the JSON output in Slack mrkdwn: who was blocked (name/email),
conversations tagged, conversations closed, and any `failures`. If `failures` is
non-empty, surface it — never report a partial block as a clean one.

## Failure modes / safety

- `no Intercom contact for email …` — the email has no Intercom contact; the
  script refuses to no-op. Verify the address, or block by `--contact-id`.
- `HTTP 4xx` on a tag/close call — first live run: smoke-test on node-8 (dry-run,
  then one `--apply` on a throwaway contact) to confirm the tag/contact/close API
  shapes before relying on the script for a real block.
- The `abuse-block` tag name MUST stay in `openclaw-edge.json` `blockedChannelTags`
  (and `$ABUSE_BLOCK_TAG` must match it) or tagging silently does nothing — the
  filter only fires on names present in that config array.
