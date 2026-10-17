---
name: paperclip-intake
description: |
  File a problem as a Paperclip card instead of DMing a human. One card per
  DISTINCT problem: filing the same problem again bumps a counter on the
  existing card. Use when you hit something a person must decide or fix
  (a failing job, a broken integration, a data problem you cannot resolve).
  Triggers: "file a card", "raise this with the team", "tell the board".
compatibility: |
  node-8 gateways (main, edge). Uses /opt/hydra/scripts/paperclip-intake.py
  (stdlib python3). The API key is a FILE, /etc/paperclip/secrets/hydra-intake,
  read at call time. Nothing to source, nothing in any env file.
metadata:
  version: "0.1"
  source-repo: "Muso-AI/hydra"
allowed-tools:
  - exec
---

# Paperclip intake

```
exec python3 /opt/hydra/scripts/paperclip-intake.py file \
  --agent <your agent id> --title "<one line, what is broken>" --body "<what you saw>"
```

It prints one JSON line: `{"action": "created"|"bumped", "identifier": ..., "occurrences": N}`.
Quote the identifier in your reply. Do not file the same problem twice by hand.

## Rules

- **Title = the problem, not the occurrence.** "deploy failed at 14:02" and "deploy
  failed at 14:09" are the same problem; times, ids, paths, urls and numbers are
  scrubbed before the dedupe hash, so they do not split cards. Put the specifics in `--body`.
- **`--component`** defaults to your agent id. Only set it when the same problem
  is reported from several agents and should land on ONE card (use a shared name).
- **Never put a secret, token, key or customer personal data in the title or body.**
  The script refuses obvious secrets; it cannot see the rest.
- Exit 0 = filed. Exit 1 = Paperclip unreachable or the key file is missing/unsafe:
  say so in your reply and fall back to your normal escalation. Exit 2 = refused input.
- A card whose earlier twin is already `done` or `cancelled` gets a NEW card: the
  problem came back.
- Attribution is self-declared (`--agent`): the key is shared.

## How cards are handled (not your job)

STAGED, INACTIVE: the pre-check and escalate crons ship `enabled: false` until the intake key is placed on node-8, so none of the following runs yet. Once they are enabled, Clio's triage wakes only when an untriaged intake card is waiting (zero-token
pre-check every 15 minutes). A card still untriaged 30 minutes after it was filed is reassigned to the
pilot agent with the `intake-escalated` label.
