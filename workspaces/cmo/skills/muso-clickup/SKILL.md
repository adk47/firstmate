---
name: muso-clickup
description: |
  ClickUp task management - READ ONLY. Query tasks, get details, view status.
  CRITICAL: This skill is READ-ONLY. Never create, update, or delete tasks.

  Use when: listing tasks, getting task details, viewing status, searching tasks,
  checking assignments.

  Triggers: "clickup", "task", "user request", "ticket", "list tasks", "show tasks"
compatibility: |
  Requires `curl` + `jq` and a `CLICKUP_API_KEY` env var. Read-only (GET requests only).
metadata:
  version: "1.0"
  source-repo: "Muso-AI/muso-skills"
allowed-tools:
  - Bash
---

# ClickUp Skill (READ-ONLY)

## Default List: Development Priorities

**Primary task list:** https://app.clickup.com/2283334/v/b/6-901214992012-2?pr=90120415925

This is the main stable list for development priorities. Sprint lists are created all the time and change frequently - use this for general understanding of priorities.

**Team ID:** `2283334`
**List ID:** `901214992012` (extracted from board view)

## ⚠️ CRITICAL: READ-ONLY ACCESS ⚠️

**THIS SKILL IS READ-ONLY. DO NOT CREATE, UPDATE, OR DELETE ANYTHING.**

The API key has write permissions, but you MUST NEVER use them:
- ❌ **DO NOT** create tasks
- ❌ **DO NOT** update task status
- ❌ **DO NOT** add comments
- ❌ **DO NOT** assign/unassign tasks
- ❌ **DO NOT** modify custom fields
- ❌ **DO NOT** delete anything

**ONLY USE GET REQUESTS. NO POST, PUT, PATCH, OR DELETE.**

## Allowed Operations (Read-Only)

> All curl commands use: `-H "Authorization: $CLICKUP_API_KEY"`

### List Tasks
```bash
# List all tasks in a list
curl -s "https://api.clickup.com/api/v2/list/LIST_ID/task" | jq

# List tasks with status filter
curl -s "https://api.clickup.com/api/v2/list/LIST_ID/task?statuses[]=to%20do&statuses[]=waiting" | jq

# List tasks assigned to someone
curl -s "https://api.clickup.com/api/v2/list/LIST_ID/task?assignees[]=ASSIGNEE_ID" | jq
```

### Get Task Details
```bash
# Get full task details
curl -s "https://api.clickup.com/api/v2/task/TASK_ID" | jq

# Get specific fields
curl -s "https://api.clickup.com/api/v2/task/TASK_ID" | \
  jq '{
    id,
    name,
    status: .status.status,
    assignees: [.assignees[].username],
    description
  }'

# Get task with custom fields (Profile ID, User Email)
curl -s "https://api.clickup.com/api/v2/task/TASK_ID" | \
  jq '{
    name,
    status: .status.status,
    profile_id: (.custom_fields[] | select(.name=="Profile ID") | .value),
    user_email: (.custom_fields[] | select(.name=="User Email") | .value)
  }'
```

### Get Task Comments
```bash
# Get comments on a task
curl -s "https://api.clickup.com/api/v2/task/TASK_ID/comment" | jq
```

### Get Lists
```bash
# Get all lists in a folder
curl -s "https://api.clickup.com/api/v2/folder/FOLDER_ID/list" | jq

# Get all lists in a space
curl -s "https://api.clickup.com/api/v2/space/SPACE_ID/list" | jq
```

### Get Team/Workspace Info
```bash
# Get authorized teams
curl -s "https://api.clickup.com/api/v2/team" | jq

# Get user info
curl -s "https://api.clickup.com/api/v2/user" | jq
```

### Search Tasks
```bash
# Search tasks by text
curl -s "https://api.clickup.com/api/v2/team/TEAM_ID/task?search=profile%20deletion" | jq

# Search with filters
curl -s "https://api.clickup.com/api/v2/team/TEAM_ID/task?search=spotify&statuses[]=waiting" | jq
```

## Common Read-Only Queries

### Get Development Priorities (Default List)
```bash
# List all tasks in development priorities
curl -s "https://api.clickup.com/api/v2/list/901214992012/task" | \
  jq '.tasks[] | {
    id,
    name,
    status: .status.status,
    priority: .priority,
    assignees: [.assignees[].username]
  }'

# Get high priority dev tasks
curl -s "https://api.clickup.com/api/v2/list/901214992012/task" | \
  jq '.tasks[] | select(.priority.priority == "high" or .priority.priority == "urgent") | {
    id,
    name,
    priority: .priority.priority,
    assignees: [.assignees[].username]
  }'

# Count tasks by status in dev priorities
curl -s "https://api.clickup.com/api/v2/list/901214992012/task" | \
  jq '[.tasks[] | .status.status] | group_by(.) |
      map({status: .[0], count: length}) |
      sort_by(.count) | reverse'
```

### List Today's To-Do Tasks
```bash
curl -s "https://api.clickup.com/api/v2/list/LIST_ID/task?statuses[]=to%20do" | \
  jq '.tasks[] | {
    id,
    name,
    assignees: [.assignees[].username],
    created: .date_created
  }'
```

### Get Task Details with Profile Info
```bash
curl -s "https://api.clickup.com/api/v2/task/TASK_ID" | \
  jq '{
    id,
    name,
    status: .status.status,
    description,
    assignees: [.assignees[].username],
    custom_fields: [
      .custom_fields[] | {
        name,
        value
      }
    ]
  }'
```

### Count Tasks by Status
```bash
curl -s "https://api.clickup.com/api/v2/list/LIST_ID/task" | \
  jq '[.tasks[] | .status.status] | group_by(.) |
      map({status: .[0], count: length}) |
      sort_by(.count) | reverse'
```

### Get Waiting Tasks
```bash
curl -s "https://api.clickup.com/api/v2/list/LIST_ID/task?statuses[]=waiting" | \
  jq '.tasks[] | {
    id,
    name,
    assignees: [.assignees[].username],
    waiting_since: .date_updated
  }'
```

## Authentication

**The API key is pre-configured in the OpenClaw gateway environment.**

All `curl` commands use `$CLICKUP_API_KEY` which is automatically available.

## Status Values Reference

User requests workflow statuses:
- `to do` - Actionable, ready to process
- `waiting` - Blocked, needs engineering fix
- `impossible` - Cannot be resolved (Spotify issues, etc.)
- `resolved` - Successfully completed

## Tips

- **READ-ONLY ONLY** - Never modify data
- Task IDs are numeric or alphanumeric
- List IDs are needed to list tasks - get from ClickUp URL
- Use `| jq` to parse and filter JSON responses
- Custom field names: "Profile ID", "User Email" (case-sensitive)
- Rate limit: 100 requests per minute per API key
- Always use `-s` (silent) flag with curl to suppress progress output

## Documentation

- ClickUp API Docs: https://clickup.com/api
- API Reference: https://clickup.com/api/clickupreference/operation/GetTasks/
