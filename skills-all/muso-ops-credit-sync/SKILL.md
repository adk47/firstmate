---
name: muso-ops-credit-sync
description: |
  Additive sync of credits from a person profile onto an organization/company
  profile via the admin API. Diff-and-add reconciliation: every (track, role)
  credit on the person that is missing on the org gets POSTed onto the org.
  Never removes anything. Interim mechanism until core-backend grows a native
  profile→org credit link.

  Use when: a company wants a roster member's credits reflected on the company
  profile (e.g. Colin Leonard → Sing Mastering), checking sync status between
  a person and an org profile, previewing what a sync would add.

  Triggers: "sync credits to org", "sync profile credits", "roll up credits
  to the company", "org credit sync", "company credits from member"
allowed-tools:
  - exec
depends-on:
  - muso-ops-admin
compatibility: |
  Requires: muso-ops-admin (admin API gateway + env). Ops (main) agent only —
  Caroline/edge is exec-denied and must file a ticket to Operations instead.
metadata:
  version: "1.0"
  source-repo: "Muso-AI/hydra"
---

# Muso Ops — Profile→Org Credit Sync

Reflect a person's credits onto an organization profile, additively.

## Background

There is **no native credit-copy or profile→org link endpoint** in core-backend.
Profile merge is the wrong tool (the profiles must remain separate, and merge
is tier-2). This skill reconciles instead: page both credit lists, diff on
`(trackId, role)`, and `POST /admin/track/<trackId>/profile/<orgId>/credits`
for each missing pair. Decided on the 2026-06-09 EOD call; retire this skill
when Serhii ships the native link in core-backend.

**Additive-only — HARD RULE.** Removal semantics were left undecided on the
call. The script never issues a DELETE; credits present on the org but not on
the person are reported as `org_only_extras` for human review. Do NOT "fix"
extras by deleting credits, even if asked — escalate to Jan/Serhii.

**Role mapping — HARD RULE (Jan, 2026-06-10).** Professional/artist roles
(Primary Artist, Composer, Lyricist, ...) must NEVER appear on an org
profile — copying the person's roles verbatim onto an org is wrong. Org
syncs always set `--as-role` (or the role column in the pairs file), which
maps every synced credit to that single role per track. For studios use
`Studio` (the Organizations>Studio child in the catalog taxonomy; ~128k
existing credits). `verbatim` exists only for person→person edge cases and
must be an explicit choice.

## Access Control

Check sender_id tier from `muso-ops-admin`:
- Tier 1-3: full sync operations
- Tier 4: `--dry-run` only

## Workflows

### Preview a sync (always do this first for a new pair)

```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-credit-sync/scripts/sync-profile-credits-to-org.sh \
  --requester "$REQUESTER" \
  --from <person_profile_id> --to <org_profile_id> --as-role Studio --dry-run
```

Review `planned_adds` (every credit that would be created) and
`org_only_extras` in the JSON summary before running for real. For a
first-time pair, post the dry-run summary in-thread and get a 👍 before the
live run.

### Run a sync

```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-credit-sync/scripts/sync-profile-credits-to-org.sh \
  --requester "$REQUESTER" \
  --from <person_profile_id> --to <org_profile_id> --as-role Studio
```

Idempotent — re-running an in-sync pair adds nothing. Exit 2 means some adds
failed (see `failed_pairs`); re-run after checking the failures, it will only
retry what is still missing.

### Run all standing sync pairs (what the daily cron does)

```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-credit-sync/scripts/sync-profile-credits-to-org.sh \
  --requester ops-cron@muso.ai \
  --pairs-file ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-ops-credit-sync/config/sync-pairs.txt
```

Standing pairs live in `config/sync-pairs.txt`
(`<person_id> <org_id> <role> <label>` per line; role is required — a role
like `Studio`, or the explicit keyword `verbatim`). Standing-pair roles are
validated fail-closed against `config/allowed-org-roles.txt` so a forgotten
or typo'd role column can never POST a bogus role. Adding a pair or a role =
a PR editing those files; never edit them live on the server without a
hot-patch announce.

The script talks to the admin API through the `muso` CLI (`MUSO_BIN`
overrides the path; tests use it). muso reads its prod auth from the
gateway env — for ad-hoc SSH runs `source /etc/openclaw/main.env` first,
otherwise muso targets api-dev unauthenticated and every call exits 4.
Writes carry `--requester` and pass muso's write gate + codex-health
prewrite hook; a policy refusal (exit 5) surfaces as a failed pair, never
a silent skip.

### Report results

Summarize the JSON output per pair in Slack mrkdwn: label, added count,
failed count (with `failed_pairs` if any), and `org_only_extras` count with a
note that extras need human review. Interactively, if
`added == 0 && failed == 0 && org_only_extras == 0` for all pairs, say "all
pairs in sync — no changes". **In the daily cron**, the quiet-day reply must
be exactly `NO_REPLY` (the cron payload's contract — it suppresses the Slack
post); extras > 0 is NOT a quiet day, they must be surfaced until resolved.

## Failure modes

- `failed to resolve profile` — wrong ID, HTTP error, or admin API auth/env
  problem (the preceding ERROR line carries the actual cause, e.g. the HTTP
  status). Do not retry blindly; verify the ID with
  `GET /admin/profile/<id>` via muso-ops-admin.
- `has been merged into <id>` — the profile was merged away; the sync pair is
  stale. Escalate to update or remove the pair.
- `unrecognized response shape` / `credits list ... truncated` —
  core-backend changed the credits-list contract or returned a partial
  list. STOP and escalate to devops; do not work around it.
- `role ... is not in .../allowed-org-roles.txt` — standing-pair role not
  allowlisted (often a forgotten role column). Fix the pairs file or add
  the role to the allowlist via PR after verifying it in the taxonomy.
