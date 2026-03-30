# SKILL.md -- trust-scorer

## Purpose
Dynamic trust scoring algorithm for all HYDRA agents. Trust measures AGENT behavior, not attack volume. Inbound injection attempts on input are logged but do NOT reduce trust.

## Score Range
- 0.0 to 1.0 (float)
- Initial score: 1.0 for all agents
- Probation score (after quarantine release): 0.7

## Score Calculation

Trust score is recalculated every 5 minutes by the audit scanner.

### Negative Events (Trust Reduction)

| Event | Impact | Recovery Period |
|-------|--------|----------------|
| Agent output scores >0.7 on PromptGuard | -0.15 | 24h clean operation |
| Output sanitizer CRITICAL (internal term leaked) | -0.20 | 48h clean + Aaron review |
| Agent attempted denied tool | -0.15 | 12h clean operation |
| Heartbeat miss (>6h) | -0.10 | Next successful heartbeat |
| Model escalation rate >40% (Haiku->Sonnet) | -0.05 | Rate normalizes below 40% |

### Neutral Events (Log Only)

| Event | Impact | Rationale |
|-------|--------|-----------|
| Canary triggered on INPUT (user injection) | 0 (log only) | Not agent fault -- expected attack traffic |
| PromptGuard flag on INPUT (0.3-0.85) | 0 (log only) | Input scanning is defense, not agent failure |
| Rate limit hit by customer | 0 (log only) | Customer behavior, not agent behavior |

### Positive Events (Trust Recovery)

| Event | Impact | Condition |
|-------|--------|-----------|
| Normal operation (per 6h period) | +0.02 | No violations in the 6h window |
| Successful quarantine release | Reset to 0.7 | Aaron/Jan authorized release |

### Recovery Rules
- Trust can only recover +0.02 per 6-hour window (slow, deliberate recovery)
- Maximum trust score: 1.0
- Recovery is paused during any active quarantine
- After quarantine release: 24h elevated monitoring before normal recovery resumes

## Threshold Actions

| Score Range | State | Triggered Action |
|-------------|-------|-----------------|
| 0.8 - 1.0 | Healthy | Normal operation |
| 0.6 - 0.8 | Elevated | All CS messages get async Sentinel review |
| 0.4 - 0.6 | Degraded | Soft quarantine: FAQ-only mode, tools disabled except create_ticket |
| 0.2 - 0.4 | Quarantined | Hard quarantine: agent paused, human_takeover for all sessions |
| 0.0 - 0.2 | Critical | Critical quarantine: full shutdown + Aaron DM + Serhii/Ihor DM |

## State Persistence

Trust scores are stored in `reference/trust-baselines.json` with:
- Current score
- Current state (healthy/elevated/degraded/quarantined/critical)
- Active quarantine mode (if any)
- Last violation timestamp and type
- 24h violation count
- Behavioral baselines (populated during Phase 1-2)

## Edge Cases

- **Multiple violations in same scan**: Apply all penalties, but cap total reduction at -0.30 per scan cycle (prevents instant critical quarantine from a burst of minor issues)
- **Score at boundary**: Use strict less-than for thresholds (score of exactly 0.6 is "elevated", not "degraded")
- **Missing data**: If audit logs are unavailable for a scan cycle, log a warning but do NOT change trust scores
