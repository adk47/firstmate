---
name: muso-ops-claiming
description: |
  Claiming operations for Muso.AI ops team. Review, approve, reject, and revert
  profile claims with integrated fraud detection, web verification, and ID checking.
  
  Replaces: Retool "Customer/Claimings" app
  
  Use when: reviewing claims, approving/rejecting claims, checking claim status,
  investigating suspicious claims, processing claim queues.

  Triggers: "claim", "claiming", "approve claim", "reject claim", "revert claim",
  "pending claims", "claim queue", "verify claim", "claiming fraud"
depends-on:
  - muso-ops-admin
  - muso-ops-audit
  - muso-ops-fraud
  - muso-verify-profile
  - muso-slack-formatter
  - muso-query-writer
compatibility: |
  Main gateway on node-8 only. Admin API + claim-history SQL go through the
  `muso` CLI (see muso-cli SKILL.md). Slack-ID→email resolution still uses
  muso-ops-admin's muso-admin-api.sh resolve-email. Also requires:
  muso-verify-profile (authenticity scoring), web_search/web_fetch (external
  verification), image tool (ID-document checks).
metadata:
  version: "1.2"
  source-repo: "Muso-AI/hydra"
  verified-against: "core-backend claiming list/reject services (2026-08-13)"
---

# Muso Ops — Claiming

End-to-end claiming workflow: review → investigate → verify → decide → execute → log.

## Access Control

Check sender_id tier from `muso-ops-admin` SKILL.md before ANY operation.
- Tier 1-3: full claiming operations
- Tier 4: read-only (view claims, no approve/reject)

## Workflows

### List Pending Claims

```bash
# Via the muso CLI (main gateway). Typed flags: --status, --limit,
# --page (1-based), --keyword, --profile-id, --profile-type, --reason.
muso claiming list --status pending --limit 20 --json
# JSON shape: {items, count, total} — each item embeds .team and .profile.

# Supplement with Trino for richer context
SELECT id, status, reason, profileid, profiletype, userid, teamid,
       verificationlinks, createdat, updatedat
FROM postgresql_core.public.claiming
WHERE status = 'pending'
ORDER BY createdat DESC
LIMIT 20
```

The admin API returns newest-first. Before any queue-sweep writes, build a
complete read-only snapshot with `--page 1, 2, 3, ...` until a page contains
fewer rows than `--limit`; never stop after the first page. Capture `total` from
page 1 and require every page's `total` to equal it. Reject an enumeration if any
exact claim ID appears twice, or if the unique accumulated count does not equal
`total`. Run a second complete enumeration immediately afterward and require the
same total and exact claim-ID set twice in a row; restart until the queue is
stable rather than processing a mixed or partial snapshot. Then sort the stable
API items by `createdAt ASC` and process oldest-first. For the Trino path, remove
the `LIMIT` and use `ORDER BY createdat ASC`.

Present as:
```
📋 *Pending Claims* (X total)

1. *#12345* — John Producer (Producer profile)
   • Submitted: 2026-03-05 • Links: spotify.com/artist/..., instagram.com/...
   • Team: john@example.com

2. *#12346* — Sarah Songwriter (Songwriter profile)
   ...
```

### Review a Claim (Deep Investigation)

When ops says "review claim 12345" or "check claim 12345":

**Step 1: Pull claim details**
```bash
muso claiming get <id> --json
```
Note: the typed command returns the claim object directly (e.g.
`jq -r '.status'`); a missing claim exits 3 (not found). The generic
`muso api GET '/admin/claiming/<id>' --json` is equivalent but wraps the
body under `.data`.

**Step 2: Pull profile data (Trino)**

Run via `muso query "<SQL>"` (use `muso query - <<'SQL'` for multi-line SQL):
```sql
SELECT _id, name, profile_type, credits_count, common_credits,
       collaborations_count, popularity, rank, ipis, country,
       genres, primary_genre, years_active
FROM hive."platform-industry-bi-prod".matvw_catalog_profile
WHERE _id = '<profile_id>' AND is_deleted = false
```

**Step 3: Check claim history (repeat claimers)**
```sql
SELECT id, status, reason, createdat, userid, teamid
FROM postgresql_core.public.claiming
WHERE profileid = '<profile_id>'
ORDER BY createdat DESC
```

**Step 4: Run profile verification** (delegate to `muso-verify-profile`)
- IPI cross-reference
- Credit source analysis (industry vs user-added)
- Collaborator quality check
- External web verification

**Step 5: Web verification of submitted links**
For each verification link the claimant submitted:
- `web_fetch` the link
- Check if the name matches the profile
- Check if music/credits match the claimed profile
- Flag mismatches

**Step 6: ID Document Verification** (if uploaded)
When ops uploads a photo ID to Slack for verification:
- Use `image` tool to read the document
- Extract: name, photo
- Cross-reference name against profile name + known aliases
- Flag if name doesn't match
- ⚠️ NEVER store the ID image or its contents — verify in-session only

**Step 7: Synthesize verdict**

Present a structured report:

```
🔍 *Claim Review: #12345*

*Claimant:* John Producer (john@example.com)
*Profile:* Producer — 247 credits, 89 collaborations
*Submitted:* 2026-03-05

*Verification Links:*
• ✅ spotify.com/artist/... — name matches, 15 tracks credited
• ✅ instagram.com/johnproducer — bio mentions production credits
• ⚠️ linkedin.com/in/john — generic name, can't confirm same person

*Authenticity Score:* 🟢 82/100
• Has IPI numbers (ASCAP) ✅
• Major label credits (Universal, Atlantic) ✅
• Credits span 2015-2026 ✅
• No prior claims on this profile ✅

*Claim History:*
• First claim on this profile ✅
• Claimant has 0 other claims ✅

*Recommendation:* APPROVE
*Reason:* Strong IPI match, major label credits verified via industry data,
Spotify page confirms identity.

Approve? (yes / reject with reason / investigate further)
```

### Approve Claim

After investigation + confirmation:

```bash
# Log BEFORE executing
# ... (audit log entry)

# Approve = verify. Write → needs --requester (the requesting human's EMAIL).
# Resolve a Slack ID to an email via the wrapper's resolver (stays on the wrapper):
#   bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-admin/scripts/muso-admin-api.sh resolve-email <SLACK_ID>
muso claiming verify <id> --requester <email> --json
```

The write is audited and echoes `>> PROD <<` on stderr — that's the expected
environment notice, not an error. Exit 0 = applied; exit 5 = policy refused
(the stderr `error.hint` names the missing artifact).

Post confirmation:
```
✅ Claim #12345 approved for John Producer.
Reason: [stated reason]
Logged to audit trail.
```

### Reject Claim

ALWAYS require a reason:

```bash
muso claiming reject <id> --reason "[reason]" --requester <email> --json
```

Standard rejection reasons:
- "Verification links don't match profile identity"
- "Suspected impersonation — name mismatch with external sources"
- "Previously rejected claim for same profile — no new evidence"
- "Insufficient verification — no matching credits in industry data"
- "already claimed by your workspace" (exact same-team artist/professional duplicate only — see Queue Sweep)

### Revert Claim

When a previously approved claim needs to be undone:

⚠️ This is a significant action — always ask WHY and confirm.

```bash
muso claiming revert <id> --requester <email> --json
```

Revert undoes an approved claim. It is a plain write-tier call (verified
against `muso agent-docs`: the dangerous tier is DELETEs plus /merge,
/reset-password, /revoke paths — revert is not among them), so
`--requester` is all the policy needs. If the gate ever refuses with
exit 5, the stderr hint names the missing artifact — supply that after
human confirmation; never pre-emptively pass `--yes`.

### Batch Review (Queue Sweep)

The following normalized block is the authoritative sweep contract. Prose in
this section may explain these directives but must not override them.

<!-- queue-sweep-contract:v1 -->
- pagination: all_pages
- processing_order: oldest_first
- stable_snapshot_passes: 2
- mutation_revalidation: per_claim
- ledger_lock: memory/claiming-escalations.lock
- lock_mode: exclusive_fail_closed
<!-- /queue-sweep-contract:v1 -->

"Show me today's claims" is read-only: use List Pending Claims above and do not
create ledger entries, send Slack posts, or change claim state. Enter this queue
sweep only when ops explicitly says "process the queue" or otherwise authorizes
claim processing.

For an authorized queue sweep:

1. Read `memory/claiming-escalations.json` and re-check every open escalation
   for new evidence or a human decision. Resolve or re-surface those entries
   before starting new work.
2. Pull ALL pending claims using full pagination, combine the pages, and sort
   oldest-first as described under List Pending Claims.
3. For each, run automated checks (Steps 2-5 above).
4. Pre-sort into: likely approve / needs review / likely reject.
5. Present the summary with recommendations.
6. Process one-by-one with confirmation, oldest-first.

Immediately before each claim mutation, re-fetch the claim with
`muso claiming get <id> --json` and require `status == pending` plus exact
`profileId` and `teamId` equality with the snapshot. Then use fully paginated
`muso claiming list --profile-id <profileId> --json` with no status filter;
require unique `count == total` and evaluate every returned status and team.
Escalate if any different-team claim with `pending` or `processed` status
appeared. Treat rejected, reverted, or closed history as risk evidence, not an
active contest. If any value changed or the history cannot be proven complete,
do not write; refresh the snapshot and re-evaluate the claim.

**Same-team duplicates:** if claim history proves an exact profile-ID and team-ID
match against an existing processed claim, recommend rejection with reason
"already claimed by your workspace". Do not infer a duplicate from similar
names or emails. The team already owns the exact profile, so this is a standing
disposition rather than an identity decision. It still requires normal write
authorization and per-item confirmation. This rule applies only to artist and
professional claims. Never use it for `profileType == organization`: organization
rejection can remove the workspace company seat and public lists, so escalate it
for a human decision instead.

**Contested claims (two DIFFERENT teams, same profile) are always human
decisions.** Add them to the Escalation Ledger and route them to the current
default target in the Operations SOUL's `## Escalation` section; do not approve
a contested claim autonomously.

**No silent abstentions.** Every pending claim older than 72h must leave the
sweep with exactly one disposition: **approve**, **reject**, or **ESCALATED**.
Escalated means both a durable ledger entry and a Slack post as defined below.
"Needs review" without those artifacts is not a disposition.

End every sweep with a digest:

```
📊 *Claiming Sweep Digest — YYYY-MM-DD*
Queue: X pending (Y older than 72h)
✅ Approved: N   ❌ Rejected: N (M same-team duplicates)
🔺 Escalated: N (new ledger entries: #id, #id)
♻️ Re-surfaced: N resolved / N still open
Oldest remaining pending: #<id> (<age>) — why it is still pending
```

**NEVER batch-approve without individual confirmation.** Even if all look clean,
confirm each one. Speed < accuracy for claiming.

## Fraud Signals (Auto-Flag)

During any claim review, automatically flag if:

- 🚩 Profile has been claimed + reverted before
- 🚩 Same user has 3+ pending claims simultaneously
- 🚩 Verification links are dead or don't contain the claimed name
- 🚩 Profile has 0 industry-captured credits (all user-added)
- 🚩 Claimant email domain doesn't match any known workspace
- 🚩 Name on profile vs name on verification links mismatch
- 🚩 Profile was recently created (< 30 days) with high credit count

When 2+ flags trigger during an explicitly authorized queue sweep, escalate via
the ledger + Slack workflow below. During a read-only review, return an
escalation recommendation only; do not create a ledger entry or Slack post.
Tier 4 is always read-only and never triggers those writes.

## Escalation Ledger (No Silent Abstentions)

Track escalations in `memory/claiming-escalations.json` in the agent workspace:

```json
{
  "escalations": [
    {
      "claimId": 12345,
      "flags": ["contested — two teams, same profile", "name mismatch"],
      "date": "2026-08-12",
      "status": "open",
      "slack_ts": "1755...",
      "resolution": null
    }
  ]
}
```

- The one lock target for every sweep process is
  `memory/claiming-escalations.lock`, resolved relative to the active agent
  workspace. Open that stable path without truncating the ledger, then acquire
  it with this exact fail-closed protocol:

  ```bash
  command -v flock >/dev/null || exit 1
  exec {claiming_lock_fd}>"memory/claiming-escalations.lock" || exit 1
  flock -x -w 30 "$claiming_lock_fd" || exit 1
  ```

  If the directory, lock-file open, `flock` lookup, or acquisition fails, halt
  the sweep with `ESCALATION LOCK FAILED`; do not read or mutate the ledger,
  post to Slack, or process later claims. All participants must use this exact
  path; never use the ledger file, a temporary file, or another path as the lock target.
- Acquire that lock before the first ledger read and hold it across the complete
  delivery transaction: validate and upsert the record, read Slack history,
  append the audit entry, post only if authoritative readback found no delivery,
  persist `slack_ts`, and re-read the ledger to verify it. Release the descriptor
  only after the verified state is durable. This serializes duplicate detection
  and Slack delivery, not merely each individual file write.
- While holding the lock, write ledger changes to a temporary file in `memory/`
  and atomically rename it over `memory/claiming-escalations.json`. If the ledger
  does not exist, initialize it once as `{"escalations": []}` through that same
  atomic path. If it exists but is malformed or `.escalations` is not an array,
  halt the sweep and report the persistence failure; never overwrite or silently
  reset it.
- Keep exactly one ledger record per `claimId`. Upsert flags and resolution into
  that record; never append a duplicate or create a second Slack post for an
  already-open claim unless the seven-day re-post rule applies.
- An open record without `slack_ts` is incomplete delivery, not a seven-day
  reminder. Search #operations history for the exact claim ID first. If the post
  exists, attach its timestamp atomically. Post exactly once only when readback
  proves it does not exist, then persist and verify the returned timestamp.
- `status` transitions from `open` to `resolved`. On resolution, record the
  disposition, who decided, and the date in `resolution`.
- Every escalation gets both artifacts during the sweep in which it is found:
  1. atomically persist the ledger entry above; then
  2. append the pre-write audit entry to `api-logs/admin/YYYY-MM-DD.jsonl`
     relative to the active agent workspace (never a hardcoded home path), then
     post in #operations,
     tagging the current default target from the Operations SOUL `## Escalation`
     section with the claim ID, profile, flags, and a one-line ask.
  Record the post's timestamp as `slack_ts` with another atomic ledger update,
  then re-read the file and verify the record before releasing the lock.
  If any persistence or post step fails, halt the sweep and report
  `ESCALATION DELIVERY FAILED`; do not treat the escalation as delivered or
  continue into later claim mutations.
- Every sweep starts by re-surfacing all `open` entries and checking whether
  new evidence or a human decision makes them resolvable. For an escalation with
  no human response after seven days, search #operations history for the claim ID
  and stored `slack_ts` before writing. Re-post only if authoritative readback
  proves no reminder landed; otherwise update `slack_ts` from the existing post.
  A failed or timed-out Slack write has unknown outcome: re-read history first and
  never blind-retry it.
- Contested claims always enter this ledger; never hardcode a person here because
  escalation ownership is maintained in the Operations SOUL `## Escalation`
  section.

## Alternatives to Suggest

When rejecting, suggest alternatives:
- "If you believe these credits are yours, update them on Spotify/your distributor first — we mirror industry data."
- "You can submit a new claim with stronger verification links."
- "If you're the manager/label, consider claiming via a workspace instead."

## Metrics

Track in `memory/ops-metrics.json`:
```json
{
  "claiming": {
    "2026-03-07": {
      "reviewed": 15,
      "approved": 10,
      "rejected": 3,
      "escalated": 2,
      "avg_review_time_min": 3.2
    }
  }
}
```
