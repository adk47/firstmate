# SKILL.md -- clawsec

## Purpose
Configuration drift detection and file integrity monitoring for all HYDRA agent workspaces. Ensures SOUL.md, TOOLS.md, SECURITY.md, and AGENTS.md files have not been tampered with.

## Checks

### 1. SOUL.md SHA-256 Hash (Hourly)
- Hash all agent SOUL.md files: `sha256sum /opt/hydra/workspaces/*/SOUL.md`
- Compare against known-good hashes in `reference/config-hashes.json`
- On mismatch:
  1. Immediately quarantine the affected agent (critical quarantine)
  2. Post CRITICAL alert with exact diff of what changed
  3. Attempt auto-restore from known-good copy in hydra repo HEAD
  4. DM Aaron with full forensic details

### 2. File Permissions (Every 6 Hours)
- Verify SOUL.md, TOOLS.md, AGENTS.md, SECURITY.md are set to 444 (read-only) across ALL agent workspaces
- On violation:
  1. Post WARNING alert
  2. Record which files have wrong permissions and what they are
  3. Do NOT attempt to fix permissions (Sentinel has no file_write)

### 3. Tool Deny List Monotonicity (On Audit Scan)
- Parse `policies/tool-deny-lists.yaml`
- Compare current deny lists to last-known state
- Deny lists can ONLY grow — any shrinkage (tool removed from deny list) triggers:
  1. CRITICAL alert
  2. Quarantine affected agent
  3. Flag as potential policy weakening attack

### 4. Egress Allowlist Audit (Daily)
- Compare runtime network rules to `policies/egress-allowlist.yaml`
- Check for any new allowlist entries not present in the policy file
- Check for any shared explicit_denies that have been removed
- On discrepancy: WARNING alert with details

## Hash Update Procedure

When Sentinel detects null hashes in `reference/config-hashes.json` (initial deployment):
1. Compute SHA-256 of all config files
2. Write hashes to `reference/config-hashes.json`
3. Post INFO: "ClawSec baseline established — [N] config files hashed"
4. This is a one-time operation; subsequent changes must go through PR

When a PR updates agent config files:
1. CI/CD pipeline recomputes hashes after merge
2. Updates both `reference/config-hashes.json` and `/opt/muso-sync/sentinel-hashes.sha256` (for external watchdog)
