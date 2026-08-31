---
name: muso-n8n
description: |
  USE THIS to manage Muso.AI's n8n workflow automation (musoai.app.n8n.cloud) via the
  Public REST API / MCP server: list, inspect, run, activate/deactivate workflows,
  monitor and retry/stop executions, and read credentials, tags, users, variables,
  projects, and data tables. ACCESS-GATED: write ops (create/update/delete/activate/
  retry/stop) are Aaron (U7RP6HKUZ) ONLY; everyone else is READ-ONLY — send write
  requests to Aaron.
---

# n8n Integration Skill

Manage n8n workflows, executions, credentials, and more via the n8n Public REST API.

## Authentication

### REST API
- API Key: `$N8N_API_KEY` env var in `~/.zshrc`
- Base URL: `$N8N_BASE_URL` env var in `~/.zshrc` → `https://musoai.app.n8n.cloud`
- Auth header: `X-N8N-API-KEY: $N8N_API_KEY`
- API version: v1 (base path: `/api/v1`)
- Key expires: 2026-03-31 (exp claim in JWT)

### MCP Server
- MCP Key: `$N8N_MCP_KEY` env var in `~/.zshrc` (separate key, aud: `mcp-server-api`)
- Endpoint: `https://musoai.app.n8n.cloud/mcp-server/http` (Streamable HTTP transport)
- Auth: `Authorization: Bearer $N8N_MCP_KEY`
- Registered in mcporter as `n8n`
- Tools: `search_workflows`, `execute_workflow`, `get_workflow_details`

## MCP Server (via mcporter)

For workflow search, details, and execution — use mcporter (simpler, richer):
```bash
# Search workflows
mcporter call n8n.search_workflows query="Company" limit:5

# Get workflow details (nodes, connections, trigger info)
mcporter call n8n.get_workflow_details workflowId=uf07pDi2fV6ObThN

# Execute a workflow
mcporter call n8n.execute_workflow workflowId=uf07pDi2fV6ObThN

# Execute with chat input
mcporter call n8n.execute_workflow workflowId=X --args '{"inputs":{"type":"chat","chatInput":"hello"}}'

# Execute with form data
mcporter call n8n.execute_workflow workflowId=X --args '{"inputs":{"type":"form","formData":{"field":"value"}}}'

# Execute with webhook data
mcporter call n8n.execute_workflow workflowId=X --args '{"inputs":{"type":"webhook","webhookData":{"method":"POST","body":{"key":"val"}}}}'
```

## REST API Script

Use the wrapper script for all other API calls:
```bash
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-n8n/scripts/n8n-api.sh <method> <endpoint> [json-body]
```

Examples:
```bash
# List all workflows
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-n8n/scripts/n8n-api.sh GET /workflows

# Get a specific workflow
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-n8n/scripts/n8n-api.sh GET /workflows/123

# Activate a workflow
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-n8n/scripts/n8n-api.sh POST /workflows/123/activate

# Deactivate a workflow
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-n8n/scripts/n8n-api.sh POST /workflows/123/deactivate

# List executions (with filters)
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-n8n/scripts/n8n-api.sh GET "/executions?status=error&limit=10"

# Retry a failed execution
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-n8n/scripts/n8n-api.sh POST /executions/456/retry

# Stop a running execution
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-n8n/scripts/n8n-api.sh POST /executions/456/stop

# List credentials
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-n8n/scripts/n8n-api.sh GET /credentials

# List tags
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-n8n/scripts/n8n-api.sh GET /tags

# List variables
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-n8n/scripts/n8n-api.sh GET /variables

# List users
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-n8n/scripts/n8n-api.sh GET /users

# Security audit
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-n8n/scripts/n8n-api.sh POST /audit

# List projects
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-n8n/scripts/n8n-api.sh GET /projects

# Source control pull
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-n8n/scripts/n8n-api.sh POST /source-control/pull '{"force": true}'
```

## API Resources

### Workflows
| Endpoint | Method | Description |
|---|---|---|
| `/workflows` | GET | List all workflows (supports `?active=true/false`, `?tags=`, `?name=`, `?limit=`, `?cursor=`) |
| `/workflows` | POST | Create a workflow (JSON body with workflow definition) |
| `/workflows/{id}` | GET | Get workflow by ID |
| `/workflows/{id}` | PUT | Update a workflow |
| `/workflows/{id}` | DELETE | Delete a workflow |
| `/workflows/{id}/{versionId}` | GET | Get a specific version of a workflow |
| `/workflows/{id}/activate` | POST | Activate a workflow |
| `/workflows/{id}/deactivate` | POST | Deactivate a workflow |
| `/workflows/{id}/tags` | PUT | Update workflow tags |
| `/workflows/{id}/transfer` | PUT | Transfer workflow to another project |

### Executions
| Endpoint | Method | Description |
|---|---|---|
| `/executions` | GET | List executions (`?status=error/success/waiting`, `?workflowId=`, `?limit=`, `?cursor=`) |
| `/executions` | DELETE | Delete executions (bulk) |
| `/executions/{id}` | GET | Get execution by ID |
| `/executions/{id}` | DELETE | Delete an execution |
| `/executions/{id}/retry` | POST | Retry a failed execution |
| `/executions/{id}/stop` | POST | Stop a running execution |
| `/executions/stop` | POST | Stop all running executions |
| `/executions/{id}/tags` | PUT | Update execution tags |

### Credentials
| Endpoint | Method | Description |
|---|---|---|
| `/credentials` | GET | List credentials |
| `/credentials` | POST | Create a credential |
| `/credentials/{id}` | GET | Get credential by ID |
| `/credentials/{id}` | PATCH | Update a credential |
| `/credentials/{id}` | DELETE | Delete a credential |
| `/credentials/schema/{typeName}` | GET | Get credential schema by type |
| `/credentials/{id}/transfer` | PUT | Transfer credential to another project |

### Tags
| Endpoint | Method | Description |
|---|---|---|
| `/tags` | GET | List all tags |
| `/tags` | POST | Create a tag |
| `/tags/{id}` | GET | Get tag by ID |
| `/tags/{id}` | PUT | Update a tag |
| `/tags/{id}` | DELETE | Delete a tag |

### Users
| Endpoint | Method | Description |
|---|---|---|
| `/users` | GET | List all users |
| `/users/{id}` | GET | Get user by ID |
| `/users/{id}/role` | PATCH | Change user role |

### Variables
| Endpoint | Method | Description |
|---|---|---|
| `/variables` | GET | List all variables |
| `/variables` | POST | Create a variable |
| `/variables/{id}` | PUT | Update a variable |
| `/variables/{id}` | DELETE | Delete a variable |

### Projects
| Endpoint | Method | Description |
|---|---|---|
| `/projects` | GET | List projects |
| `/projects` | POST | Create a project |
| `/projects/{projectId}` | GET | Get project by ID |
| `/projects/{projectId}` | PUT | Update a project |
| `/projects/{projectId}` | DELETE | Delete a project |
| `/projects/{projectId}/users` | PUT | Set project users |
| `/projects/{projectId}/users/{userId}` | DELETE | Remove user from project |

### Data Tables
| Endpoint | Method | Description |
|---|---|---|
| `/data-tables` | GET | List data tables |
| `/data-tables/{tableId}` | GET | Get data table by ID |
| `/data-tables/{tableId}/rows` | GET | List rows in a data table |
| `/data-tables/{tableId}/rows` | POST | Insert rows |
| `/data-tables/{tableId}/rows/update` | PATCH | Update rows |
| `/data-tables/{tableId}/rows/upsert` | POST | Upsert rows |
| `/data-tables/{tableId}/rows/delete` | DELETE | Delete rows |

### Other
| Endpoint | Method | Description |
|---|---|---|
| `/audit` | POST | Run a security audit |
| `/source-control/pull` | POST | Pull from source control |

## Pagination
All list endpoints support cursor-based pagination:
- `?limit=N` — results per page (default varies by endpoint)
- `?cursor=<string>` — cursor from previous response's `nextCursor` field

## Write Access Policy
- **Aaron (U7RP6HKUZ) = full access.** Create, update, delete workflows, credentials, variables, etc.
- **Everyone else = READ ONLY.** Can list/get workflows, executions, credentials, tags, users, variables.
  - ❌ BLOCKED: Create, update, delete, activate, deactivate, retry, stop
  - If someone asks for a write op, tell them to ask Aaron

## Common Use Cases

### Monitor Failed Executions
```bash
# Get recent failures
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-n8n/scripts/n8n-api.sh GET "/executions?status=error&limit=20"
```

### Workflow Inventory
```bash
# List all active workflows
bash ${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/muso-n8n/scripts/n8n-api.sh GET "/workflows?active=true"
```

### Troubleshooting
1. List recent executions for a workflow: `GET /executions?workflowId=X&limit=10`
2. Get execution details for error info: `GET /executions/{id}`
3. Retry if appropriate: `POST /executions/{id}/retry`

## Troubleshooting
- If API returns 401: key may be expired (check exp claim) or wrong
- If API returns 404: check N8N_BASE_URL is set correctly
- If connection refused: n8n instance may be down
