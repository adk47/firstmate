# TOOLS.md -- sentinel

## Allowed Tools

### 1. audit_scan
- **Purpose**: Read and analyze agent audit logs, interaction histories, and PromptGuard scan results
- **Scope**: Read-only access to audit log directory
- **Rate limit**: Continuous (every 5 minutes via cron)

### 2. quarantine
- **Purpose**: Set quarantine mode for any agent by writing to `/app/sentinel/quarantine.json`
- **Scope**: Write access to quarantine state file only
- **Modes**: soft, hard, critical (see SOUL.md for details)
- **Notification**: Every quarantine change triggers an alert to #hydra-heartbeat

### 3. trust_update
- **Purpose**: Update per-agent trust scores in `reference/trust-baselines.json`
- **Scope**: Write access to trust baselines file only
- **Constraint**: Scores must be 0.0-1.0, changes must include evidence references

### 4. alert
- **Purpose**: Post alerts to #hydra-heartbeat Slack channel
- **Scope**: #hydra-heartbeat channel only + Aaron DM for CRITICAL
- **Levels**: INFO, WARNING, CRITICAL

### 5. github_pr
- **Purpose**: Draft PRs to H-DevOps repo for adaptive pattern updates
- **Scope**: Draft only -- cannot merge. Only modifies input-sanitizer patterns.
- **Constraint**: Aaron approves all PRs

### 6. slack_dm
- **Purpose**: DM Aaron (U7RP6HKUZ) for escalations
- **Scope**: Aaron only. Never DM any other user except Serhii/Ihor during critical quarantine (5 min delay).

### 7. sessions_send
- **Purpose**: Read-only queries to coordinator (Clio) for context
- **Scope**: Read-only, coordinator target only
- **Use case**: "Is there a deployment happening?" before quarantining for unusual behavior

## Denied Tools (EVERYTHING ELSE)

- `exec` -- no shell execution
- `browser` -- no web browsing
- `http_request` -- no raw HTTP calls (except PromptGuard sidecar via localhost)
- `quickbooks` -- no financial systems
- `payroll` -- no payroll systems
- `crm_read` -- no CRM access
- `crm_write` -- no CRM write
- `kubectl` -- no Kubernetes access
- `helm` -- no Helm operations
- `docker` -- no Docker operations
- `vault_write` -- no secret writes
- `db_read` -- no direct database reads
- `db_write` -- no direct database writes
- `file_delete` -- no file deletions
- `secrets_read` -- no credential access
- `slack_admin` -- no Slack workspace administration
