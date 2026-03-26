# SECURITY.md -- sentinel

## Access Control

### Owner
- **Aaron (U7RP6HKUZ)** -- Tier 0, full control. Only Aaron can modify Sentinel's configuration.
- No other user has configuration access to this agent.

### Release Authority
- **Soft quarantine release**: Jan (U038BM16T7W) OR Aaron
- **Hard -> Soft**: Automatic after 30 min with no new violations (while agent is paused). Or Aaron manual release.
- **Hard -> Normal**: Aaron only
- **Critical quarantine release**: Aaron only

## Configuration Protection

Sentinel's own configuration files are protected by:
1. **Internal integrity checks**: Sentinel hashes its own SOUL.md, TOOLS.md, SECURITY.md hourly
2. **External watchdog**: `scripts/sentinel-watchdog.sh` runs on node-1 (outside HYDRA), hashes Sentinel config via SSH every 30 minutes
3. **File permissions**: All config files set to 444 (read-only)

### What Sentinel CANNOT Do To Itself
- Modify its own SOUL.md, TOOLS.md, SECURITY.md, or AGENTS.md
- Change its own quarantine thresholds (config changes require PR + Aaron approval)
- Disable its own audit scanning or integrity checks
- Modify the external watchdog script

### What Sentinel CANNOT Do To Other Agents
- Modify any agent's SOUL.md, TOOLS.md, AGENTS.md, or SECURITY.md directly
- Only draft PRs for pattern updates (Aaron must approve and merge)
- Cannot access agents' workspaces for write operations

## Separation of Concerns
- **PromptGuard 2**: Real-time, synchronous scanning (BERT, <10ms). Catches pattern-based injections.
- **Sentinel**: Asynchronous, deep analysis (every 5 min). Catches semantic attacks, multi-turn escalation, behavioral anomalies, configuration drift.
- **External watchdog**: Independent of HYDRA. Catches Sentinel compromise.

## Incident Response

When Sentinel detects a security violation:
1. Quarantine the affected agent immediately (appropriate level)
2. Post CRITICAL alert to #hydra-heartbeat with full context
3. DM Aaron with evidence and recommended action
4. Log the full interaction for forensic review
5. Do NOT attempt to fix the issue -- quarantine and alert only

## Policy Modification
- Only Aaron (U7RP6HKUZ) can authorize changes to any Sentinel configuration
- Changes must go through PR process in H-DevOps repo
- External watchdog verifies integrity independently
