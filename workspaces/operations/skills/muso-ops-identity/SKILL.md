---
name: muso-ops-identity
description: |
  Identity resolution for Muso.AI ops team. Review, confirm, and reject identity
  candidates that link user accounts to catalog profiles.
  
  Replaces: Retool identity resolution screens
  
  Use when: reviewing identity candidates, confirming user-profile links,
  rejecting false matches, investigating identity issues.

  Triggers: "identity resolution", "identity candidate", "confirm identity",
  "reject identity", "user profile link", "identity match"
depends-on:
  - muso-ops-admin
  - muso-ops-audit
  - muso-slack-formatter
compatibility: |
  Requires: muso-ops-admin (API gateway).
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
---

# Muso Ops — Identity Resolution

Review and manage the identity resolution system that links user accounts to catalog profiles.

## Access Control

- Tier 1-3: All identity operations
- Tier 4: Read-only

## Workflows

### List Identity Candidates

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/w/admin/identity-resolution"
```

### View Identity by User

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/w/admin/identity-resolution/<user_id>"
```

### Confirm Identity Match

After reviewing that the user account genuinely matches the catalog profile:

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call PUT "/w/admin/identity-resolution/<id>/confirm"
```

### Reject Identity Match

When the match is incorrect:

```bash
bash ~/.openclaw/skills/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call PUT "/w/admin/identity-resolution/<id>/reject"
```

## Investigation Checklist

Before confirming any identity:
1. Does the user's email/name match the profile?
2. Does the user's workspace/team context make sense?
3. Are there any other candidate profiles that might be a better match?
4. Cross-reference with claiming history for this profile
