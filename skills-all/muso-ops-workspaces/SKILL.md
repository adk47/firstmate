---
name: muso-ops-workspaces
description: |
  Workspace (team) management for Muso.AI ops team. Create workspaces, manage roster,
  add/remove users and profiles, handle seat management and cleansing.
  
  Replaces: Retool workspace creation and management workflows
  
  Use when: creating workspaces for B2B clients, managing roster profiles, adding
  users to workspaces, workspace cleansing, seat management.

  Triggers: "create workspace", "workspace", "roster", "add profile", "add user",
  "cleansing", "seat", "b2b onboarding", "workspace setup"
depends-on:
  - muso-ops-admin
  - muso-ops-audit
  - muso-ops-profiles
  - muso-slack-formatter
compatibility: |
  Requires: muso-ops-admin (API gateway), muso-ops-profiles (for profile operations).
metadata:
  version: "1.2"
  source-repo: "Muso-AI/muso-skills"
  verified-against: "core-backend/src/apis/index.w.js (2026-04-28)"
---

# Muso Ops — Workspace Management

B2B workspace lifecycle: create → populate → cleanse → deliver.

## Access Control

- Tier 1-2: All workspace operations
- Tier 3: View workspaces, manage roster (add/remove profiles). NO create/delete workspace.
- Tier 4: Read-only

## Quick Check: "Does email X have a workspace?"

⚡ **FAST PATH — one Trino query (via `trino-query.sh`), batch-friendly. Run this immediately, don't pre-announce.**

The admin API has no `/admin/team?keyword=<email>` filter — `GET /admin/team/details`
needs a team id, and `GET /admin/user?keyword=<email>` only returns the user.
Per-email API roundtrips are slow and the workspace-lookup endpoint variants
return errors when called this way (see 2026-05-01 #operations triage).
Skip the API and go straight to the join below — fast and reliable.

```bash
bash /opt/hydra/scripts/trino-query.sh "
SELECT
  u.email                  AS user_email,
  u.id                     AS user_id,
  t.id                     AS workspace_id,
  t.name                   AS workspace_name,
  t.email                  AS workspace_email,
  tu.roles                 AS roles,
  (t.id = u.defaultteamid) AS is_default_workspace
FROM postgresql_core.public.users u
LEFT JOIN postgresql_core.public.team_users tu
  ON tu.userid = u.id
LEFT JOIN postgresql_core.public.teams t
  ON t.id = tu.teamid
WHERE lower(u.email) IN ('email1@example.com','email2@example.com')
ORDER BY u.email, is_default_workspace DESC
"
```

Membership lives in `team_users` (`userid`, `teamid`, `roles` json) — there is no
`workspace_members` table under any naming form.

**Result interpretation:**
- Email **not in any row** → no Muso user account for that email.
- Email present, `workspace_id` IS NULL → user exists, no workspace memberships.
- Multiple rows per email → user belongs to multiple workspaces (rare for B2B).

**Reply format (post one block per email; this is what Aaron expects):**
```
<email>
Has workspace: yes/no
User id: <user_id>
Workspace id: <workspace_id>
Workspace email: <workspace_email>
Roles: <roles>
Default workspace: yes/no
```

Target round-trip: under 30s for any number of emails. If the query errors,
report the actual error verbatim — don't silently retry through the API.

## Workspace Creation Workflow

Based on Retool docs, the full B2B onboarding flow:

### Step 1: Create Account
Need: one email (main contact)
```bash
# Workspace = "team" in admin API
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/team" '{"email":"contact@label.com","name":"Label Name"}'
```

### Step 2: Add Logo
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  upload PUT "/admin/team/<id>/image" /tmp/logo.jpg
```

### Step 3: Add Users
First check if user exists:
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/user?keyword=user@email.com"
```

If new, create:
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/user" '{"email":"user@email.com","firstName":"Name","password":"name+muso"}'
```

Then add to workspace:
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/team/<id>/users" '{"userId":"<user_id>"}'
```

Or invite by email:
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/team/<id>/invite-users" '{"emails":["user@email.com"]}'
```

⚠️ **Password note:** Once created, password can't be "fixed" — must delete and recreate user.

### Step 4: Add Profiles to Roster (Seats)
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/team/<id>/seats" '{"profileId":"<profile_id>"}'
```

Toggle seat active status:
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call PUT "/admin/team/<id>/seats/<seat_id>" '{"seatActive":true}'
```

### Step 5: Request Cleansing
Post to #b2b-onboarding: "[Workspace Name] needs to be cleansed"
Catalog team merges profiles and keeps correct ones.

### Step 6: Review Analytics
Verify analytics are populating before delivering to client.

### Step 7: Send User Logins
- Small batch: individual emails
- Large batch (20+): use Klaviyo

## Seat Management

Get all seats:
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/team/<id>/seats"
```

Toggle analytics gathering:
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call PUT "/admin/team/<id>/seats/<seat_id>" '{"seatActive":true}'
```

Remove seat:
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call DELETE "/admin/team/<id>/seats/<seat_id>"
```

## Encore Shareables

For pre-sale and influencer plaque management:
- Each influencer needs their own workspace where they're the ONLY owner
- Can override email from the workspace settings

## Workspace API Keys

For partner integrations:
```bash
# Add key
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/workspace/<workspace_id>/key"

# Remove key
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call DELETE "/admin/workspace/<workspace_id>/key"
```

## Conversational Flow

When ops says "set up a workspace for Label X":

```
Clio: "Setting up workspace for Label X. I need:
1. Main contact email
2. Logo (upload to this thread)
3. User list (emails + names)
4. Profile list (Muso IDs or Spotify links)

What do you have?"

[Ops provides info step by step]

Clio: [Creates workspace, adds users, adds profiles]
"✅ Workspace 'Label X' created:
• 3 users added (with default passwords)
• 12 profiles on roster (seats active)
• Cleansing request posted to #b2b-onboarding
• Analytics should populate within 24-48h

Want me to send login credentials to users, or wait for cleansing first?"
```
