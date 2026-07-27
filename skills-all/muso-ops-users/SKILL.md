---
name: muso-ops-users
description: |
  User account management for Muso.AI ops team. Lookup, update, reset passwords,
  confirm emails, and manage user accounts.
  
  Replaces: Retool "Users > List" and user management screens
  
  Use when: looking up users, resetting passwords, confirming emails, managing
  user accounts, investigating user issues.

  Triggers: "user lookup", "find user", "reset password", "confirm email",
  "user details", "delete user", "user management", "impersonate"
depends-on:
  - muso-ops-admin
  - muso-ops-audit
  - muso-amplitude
  - muso-stripe
  - muso-intercom
  - muso-slack-formatter
compatibility: |
  Requires: muso-ops-admin (API gateway), Trino, Amplitude, Stripe, Intercom
  for comprehensive user investigation.
metadata:
  version: "1.1"
  source-repo: "Muso-AI/muso-skills"
  verified-against: "core-backend/src/apis/index.w.js (2026-04-28)"
---

# Muso Ops — User Management

Comprehensive user account operations with cross-system investigation.

## Access Control

- Tier 1: All operations including delete and impersonate
- Tier 2-3: Lookup, reset password, confirm email. NO delete/impersonate.
- Tier 4: Read-only lookup

## Workflows

### User Lookup (Comprehensive)

When ops says "find user john@example.com", pull from ALL sources:

**Step 1: Admin API**
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call GET "/admin/user?keyword=john@example.com&limit=10"
```

**Step 2: Trino (account data)**
```sql
SELECT id, email, first_name, last_name, createdat, updatedat, status
FROM postgresql_core.public.users
WHERE lower(email) = 'john@example.com'
```

**Step 3: Stripe (subscription/payment data)**
```bash
stripe customers search --query "email:'john@example.com'" --limit 5
```

**Step 4: Amplitude (activity)**
Use the Muso internal user ID (from Step 2) to search Amplitude.

**Step 5: Intercom (support history)**
Check for any open conversations or recent support tickets.

**Present unified profile:**
```
👤 *User: John Example*
• Email: john@example.com
• User ID: 325276
• Created: 2024-06-15
• Status: active

*Subscription:*
• Plan: Pro Monthly ($9.99/mo)
• Since: 2024-07-01
• Status: active
• Customer: cus_ABC123

*Activity (Amplitude):*
• Last seen: 2026-03-06
• Events (30d): 247
• Top actions: analytics_view (89), profile_view (45), credits_edit (12)

*Support:*
• Open tickets: 0
• Last conversation: 2026-02-15 — resolved

*Claiming:*
• 1 approved claim — Producer profile (profile_id)

*Workspace:*
• "John's Studio" — 3 profiles, 2 members
```

### Reset Password

```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/user/<user_id>/reset-password"
```

### Confirm Email

```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call POST "/admin/user/<user_id>/email-confirmed"
```

### Update User

```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call PUT "/admin/user/<user_id>" '{"field":"value"}'
```

### Delete User ⚠️ AARON ONLY

```bash
# REQUIRES: sender_id == U7RP6HKUZ
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  call DELETE "/admin/user/<user_id>"
```

### Upload User Image

When ops shares an image in Slack:
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh \
  upload "/admin/user/<user_id>/image" /tmp/user-image.jpg
```

## Multi-Step Workflows

### "User can't log in"
1. Look up user → check account status
2. Check if email is confirmed → if not, confirm it
3. Check Auth0 status (if accessible)
4. Reset password if needed
5. Update Intercom ticket if one exists

### "User says credits are wrong"
1. Look up user → find their claimed profiles
2. Pull profile credits from Trino
3. Check raw credits vs displayed credits
4. Cross-reference with industry data
5. Identify the gap
6. Either: fix via admin API, or explain that credits come from industry sources

### "User wants to cancel + refund"
1. Look up user → get Stripe customer
2. Check activity (Amplitude) — were they active?
3. Delegate to `muso-refund-processor` skill for investigation + execution
