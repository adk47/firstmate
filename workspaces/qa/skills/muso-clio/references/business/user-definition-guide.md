# User Definition Guide - Resolving Ambiguity

## The Problem

When someone asks "How many users...", there are multiple valid interpretations:

| Term | Database Meaning | Count Source |
|------|------------------|--------------|
| **User** | Account in `users` table | `SELECT COUNT(*) FROM users WHERE ...` |
| **Claimed user** | User who claimed ≥1 profile | Join `users` → `public_claiming` |
| **Paying user** | User with active subscription | Join `users` → `subscriptions WHERE status='active'` |
| **Workspace owner** | User who created/owns a workspace | `workspaces WHERE creator_id=...` |
| **Workspace member** | User with seat in a workspace | `public_roster_seats` |
| **Profile owner** | User who claimed a specific profile | `public_claiming WHERE status='processed'` |

## When to Ask Clarifying Questions

**ALWAYS ask for clarification when queries involve "users" in these contexts:**

### Ambiguous Query Patterns

```
❌ "How many users have 1M+ streams?"
   → Ask: "By users, do you mean:
      • Unique user accounts who claimed profiles with 1M+ streams?
      • Workspace owners whose roster has 1M+ streams?
      • Paying users (active subscriptions) with 1M+ streams?"

❌ "How many users added credits?"
   → Ask: "Do you mean:
      • Users who manually added credits (user-added)?
      • All users who have credits (including system-added)?
      • Users with active subscriptions who added credits?"

❌ "How many users are on Pro?"
   → Ask: "Do you mean:
      • Individual user accounts with Pro subscriptions?
      • Workspace owners with Pro plans?
      • Total seats across all Pro workspaces?"
```

## Standard Clarifying Questions Template

When you encounter an ambiguous user query, use this template:

```markdown
To give you the right numbers, I need to clarify what you mean by "users":

1. **User accounts** - Unique entries in the users table (email-based accounts)
2. **Claimed users** - Users who claimed at least 1 profile
3. **Paying users** - Users with active subscriptions (Lite/Pro/Business)
4. **Workspace owners** - Users who created/own a workspace
5. **Workspace members** - Users with seats in any workspace (including roster members)

Which definition fits your question?
```

## Common Query Patterns - Resolved

### Pattern: "Users with X streams"

**Likely meaning:** Users who claimed profiles that have X streams

**Query approach:**
1. Find profiles with X streams (`tracks` → `lifetime_streams`)
2. Join to `public_claiming` (profile ownership)
3. Count distinct `user_id`

**Clarify if unclear:** "Do you want users who *own* profiles with X streams, or users in workspaces that *manage* profiles with X streams?"

### Pattern: "Users who added credits"

**Likely meaning:** User-added credits (not system-added)

**Query approach:**
1. Filter `credits` where `added.by.type = 'user'`
2. Join to `users` table
3. Count distinct users

**Clarify if unclear:** "Do you mean credits added manually by users, or all credits (including system-imported)?"

### Pattern: "Users on [Plan]"

**Likely meaning:** Users with active subscriptions on that plan

**Query approach:**
1. Filter `subscriptions` WHERE `status='active'` AND `plan_name='...'`
2. Count distinct `user_id`

**Clarify if unclear:** "Do you want individual user subscriptions, or workspace-level seats?"

### Pattern: "Users in workspaces"

**Multiple meanings - ALWAYS clarify:**

**Option A:** Workspace owners
```sql
SELECT COUNT(DISTINCT creator_id) FROM workspaces
```

**Option B:** All workspace members (owners + roster)
```sql
SELECT COUNT(DISTINCT user_id) FROM public_roster_seats
```

**Ask:** "Do you mean workspace owners, or all users with seats (owners + members)?"

## Decision Tree for "User" Queries

```
User query received
    ↓
Does it mention "claimed"?
    YES → User who claimed profile(s)
    NO  ↓
Does it mention "subscription" or "paid"?
    YES → User with active subscription
    NO  ↓
Does it mention "workspace"?
    YES → Ask: "Owner or member?"
    NO  ↓
Does it mention profile-level data (streams, credits, tracks)?
    YES → Likely: User who owns/claimed profiles
    NO  ↓
Is it asking about accounts/authentication?
    YES → User records in users table
    NO  → ASK FOR CLARIFICATION (default fallback)
```

## Examples - Good vs Bad

### ❌ BAD - Assumed Definition
```
User: "How many users have 1M+ streams?"
Clio: "23,895 users"
```
**Problem:** Didn't clarify if this means claimed users, paying users, workspace owners, etc.

### ✅ GOOD - Clarified First
```
User: "How many users have 1M+ streams?"
Clio: "To give you accurate numbers, do you mean:
       • User accounts who claimed profiles with 1M+ streams?
       • Or workspace owners whose rosters have 1M+ combined streams?"

User: "User accounts who claimed profiles"
Clio: "23,895 user accounts have claimed profiles with 1M+ lifetime streams."
```

## When NOT to Ask

**Don't ask for clarification when the query is already specific:**

✅ "How many claimed profiles have 1M+ streams?" → Clear (profiles, not users)
✅ "How many active subscriptions are on Pro?" → Clear (subscriptions, not users)
✅ "How many workspace owners..." → Clear (owners specifically stated)
✅ "How many user accounts were created last month?" → Clear (user table records)

## Key Takeaway

**Default rule:** If someone says "users" without qualification AND the query involves workspaces, claims, subscriptions, or profile data → ASK FOR CLARIFICATION before running the query.

Better to ask once than to return wrong numbers.
