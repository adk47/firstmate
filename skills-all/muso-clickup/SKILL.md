---
name: muso-clickup
description: |
  ClickUp task management - READ ONLY. Query tasks, get details, view status,
  through the gated `muso clickup` provider.
  Reads (tasks list/get/comments) are ungated; the write commands exist but are
  policy-gated + audited — this skill never uses them.

  Use when: listing tasks, getting task details, viewing status, searching tasks,
  checking assignments.

  Triggers: "clickup", "task", "user request", "ticket", "list tasks", "show tasks"
compatibility: |
  Main gateway on node-8 only. Driven by the `muso` host binary —
  `muso clickup …` (see muso-cli SKILL.md for the output/exit-code contract).
  Requires the muso binary that ships the `clickup` command (v0.3.0+); until
  that release is pinned by deploy.sh, fall back to the raw `curl` form (a
  `muso clickup raw GET <path>` is the same call as
  `curl -H "Authorization: $CLICKUP_API_KEY" https://api.clickup.com/api/v2<path>`).
  The token rides `CLICKUP_API_KEY` (same var as before).
depends-on:
  - muso-cli
metadata:
  version: "1.2"
  source-repo: "Muso-AI/hydra"
allowed-tools:
  - exec
---

# ClickUp Skill (READ-ONLY)

## Known lists

**Team ID:** `2283334`

| List | ID | URL |
|---|---|---|
| **User Requests** (support board) | `901000600160` | https://app.clickup.com/2283334/v/b/6-901000600160-2 |
| **Development Priorities** | `901214992012` | https://app.clickup.com/2283334/v/b/6-901214992012-2?pr=90120415925 |

When Jan (or ops) asks about tickets, user requests, UVN sweeps, or "to do"
items, they almost always mean the **User Requests** board `901000600160`.
Development Priorities is the stable dev list (sprint lists change frequently).
Other boards exist — resolve their ids via the hierarchy `raw GET` commands
below (`/folder/<id>/list`, `/space/<id>/list`), or from a ClickUp URL
(`…/v/b/6-<LIST_ID>-2`).

**Always pass `--list <id>` explicitly.** There is NO `CLICKUP_LIST_ID` env
default in the gateway exec environment (verified on node-8 2026-07-24) — a
`tasks list` without `--list` fails with `no list id`.

## ⚠️ READ-ONLY — now structurally enforced

The token has write permissions, but this skill MUST NEVER use them. Under
`muso clickup`, that split is no longer prose-only:

- **Reads** — `tasks list`, `tasks get`, `tasks comments`, `whoami`, and
  `raw GET …` — are **ungated**. Use these.
- **Writes** — `tasks create/update/comment/tag` (and `delete`) — require
  `--requester` and are **audited**; `delete` is dangerous-tier. **Do not call
  them from this skill.** A stray write fails the gate loudly rather than
  silently mutating the board.

So: only `muso clickup tasks list|get|comments`, `whoami`, and `raw GET`.

> **Envelope:** every `muso … --json` result is one object `{data: …}`. The raw
> ClickUp body (e.g. `{tasks:[…]}`) is under `.data` — peel it first in `jq`
> (the examples do).

## Allowed operations (read-only)

### List tasks
```bash
# All tasks in a list
muso clickup tasks list --list 901214992012 --json | jq '.data.tasks[]'

# Status filter (ClickUp array params ride a repeatable --query)
muso clickup tasks list --list 901214992012 \
  --query 'statuses[]=to do' --query 'statuses[]=waiting' --json | jq '.data.tasks[]'

# Assigned to someone
muso clickup tasks list --list 901214992012 --query 'assignees[]=ASSIGNEE_ID' --json | jq '.data.tasks[]'
```

### Get task details
```bash
muso clickup tasks get --task TASK_ID --json | jq '.data | {
  id, name, status: .status.status,
  assignees: [.assignees[].username], description
}'

# With custom fields (Profile ID, User Email)
muso clickup tasks get --task TASK_ID --json | jq '.data | {
  name, status: .status.status,
  profile_id: (.custom_fields[] | select(.name=="Profile ID") | .value),
  user_email: (.custom_fields[] | select(.name=="User Email") | .value)
}'
```

### Get task comments
```bash
muso clickup tasks comments --task TASK_ID --json | jq '.data'
```

### Lists / hierarchy / search / identity (via raw GET)
The long tail — folder/space lists, team task search, hierarchy — has no typed
command; use `raw GET <path>` (relative to `/api/v2`):
```bash
muso clickup raw GET /folder/FOLDER_ID/list --json | jq '.data'
muso clickup raw GET /space/SPACE_ID/list   --json | jq '.data'
muso clickup raw GET /team/TEAM_ID/task --query 'search=profile deletion' --json | jq '.data.tasks[]'
muso clickup raw GET /team --json | jq '.data'    # authorized teams
muso clickup whoami --json | jq '.data'           # token's user (GET /user)
```

## Common read-only queries

```bash
# Development priorities, shaped
muso clickup tasks list --list 901214992012 --json | jq '.data.tasks[] | {
  id, name, status: .status.status, priority: .priority,
  assignees: [.assignees[].username]
}'

# High/urgent priority dev tasks
muso clickup tasks list --list 901214992012 --json \
  | jq '.data.tasks[] | select(.priority.priority == "high" or .priority.priority == "urgent")
        | {id, name, priority: .priority.priority, assignees: [.assignees[].username]}'

# Count tasks by status
muso clickup tasks list --list 901214992012 --json \
  | jq '[.data.tasks[].status.status] | group_by(.) | map({status: .[0], count: length}) | sort_by(.count) | reverse'

# Waiting tasks
muso clickup tasks list --list LIST_ID --query 'statuses[]=waiting' --json \
  | jq '.data.tasks[] | {id, name, assignees: [.assignees[].username], waiting_since: .date_updated}'
```

> **Pagination:** `tasks list` returns ≤100 tasks per page with `last_page` in
> the body. For a board larger than one page, loop `--query 'page=N'` from 0
> until `.data.last_page == true`.

## Status values reference

User-requests workflow statuses:
- `to do` — actionable, ready to process
- `waiting` — blocked, needs engineering fix
- `impossible` — cannot be resolved (Spotify issues, etc.)
- `resolved` — successfully completed

## Tips

- **READ-ONLY** — only `tasks list|get|comments`, `whoami`, `raw GET`.
- Task IDs are numeric or alphanumeric; list IDs come from the ClickUp URL.
- Custom field names: "Profile ID", "User Email" (case-sensitive).
- Rate limit: 100 requests/min/key (the provider backs off on 429 automatically).
- Peel `.data` before shaping with `jq`.

## Documentation
- ClickUp API: https://clickup.com/api · Reference:
  https://developer.clickup.com/reference
