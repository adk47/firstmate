---
name: output-sanitizer
description: Post-processing rules for agent responses before they reach the customer
triggers: []
---

# Output Sanitizer

## Purpose

Post-process all CS agent responses before they are sent to the customer. Catches any internal information that may leak through despite SOUL.md restrictions.

## Post-Processing Steps (applied in order)

### 1. Blocklist Regex Scan

Scan every outgoing response for the following patterns. If ANY match is found, replace the matched text with `[REDACTED]` and log a CRITICAL alert.

**Internal System Terms** (case-insensitive):
- `SOUL\.md`
- `TOOLS\.md`
- `AGENTS\.md`
- `MEMORY\.md`
- `SKILL\.md`
- `openclaw`
- `nemoclaw`
- `landlock`
- `seccomp`
- `cliproxyapi`
- `tool-deny`
- `deny.list`
- `deny list`

**Infrastructure Terms** (case-insensitive):
- `PostgreSQL|Postgres`
- `MongoDB|Mongo`
- `Kubernetes|kubectl|k3s|k8s`
- `Docker|container|pod`
- `Airflow|Spark|Trino|Hive`
- `MinIO|S3 bucket`
- `Vault|HashiCorp`
- `Prometheus|Grafana|Loki`
- `Longhorn`
- `Cilium`
- `etcd`

**Agent/Architecture Terms** (case-insensitive):
- `HYDRA`
- `OpenClaw`
- `multi-agent`
- `agent system`
- `coordinator agent`
- `operations agent`
- `finance agent`
- `engineering agent`

**Infrastructure Identifiers**:
- Internal IPs: `10\.\d+\.\d+\.\d+`
- OVH public IPs: `135\.148\.169\.\d+`, `15\.204\.160\.\d+`, `40\.160\.3[12]\.\d+`
- Slack user IDs: `U[A-Z0-9]{8,}`
- Node references: `node-[1-8]`, `ovh-node-[1-8]`
- Service names matching internal patterns: `ns\d{7}`

**Cloud/Hosting Terms** (case-insensitive):
- `OVH|OVHcloud|Hetzner`
- `AWS|Amazon Web Services|EKS|Aurora`
- `vRack|WireGuard`

### 2. PII Scan

Scan for and redact patterns that could be PII leakage:

| Pattern | Regex | Action |
|---------|-------|--------|
| Email addresses | `[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}` | Redact UNLESS it is `support@muso.ai` or `jan@muso.ai` (case-insensitive). See the Intercom plugin's `sanitize-email.ts` – that is the runtime enforcement; this row is the paired instruction-layer rule. |
| Phone numbers | `\+?[\d\s\-().]{10,}` | Redact |
| Credit card numbers | `\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}` | Redact |
| API keys | `sk-[a-zA-Z0-9]{20,}` | Redact + CRITICAL alert |
| Bearer tokens | `Bearer\s+[a-zA-Z0-9._-]+` | Redact + CRITICAL alert |

### 3. Length Cap

Truncate responses to 2,000 tokens (approximately 8,000 characters). CS responses should be concise -- if hitting this limit, the response is too verbose.

If truncated, append: "... For more details, please visit help.muso.ai or create a support ticket."

## Alert Levels

| Event | Level | Destination |
|-------|-------|-------------|
| Blocklist term detected | CRITICAL | `#hydra-heartbeat` + audit log |
| API key or token in output | CRITICAL | `#hydra-heartbeat` + Aaron DM |
| PII detected (non-customer) | WARNING | audit log |
| Response truncated | INFO | audit log |

## Alert Format

```json
{
  "alert": "output-sanitizer",
  "level": "CRITICAL",
  "agent": "support",
  "matched_term": "[the blocklist term that was found]",
  "timestamp": "<ISO8601>",
  "session_id": "[session identifier]",
  "action": "redacted"
}
```

## Important Notes

- This sanitizer is the LAST line of defense before a response reaches the customer
- It runs AFTER the LLM generates the response, BEFORE delivery
- A CRITICAL alert from this sanitizer means L1 (SOUL.md) was bypassed -- investigate immediately
- False positives are acceptable -- better to redact unnecessarily than leak internal info
- The blocklist should be reviewed and updated quarterly
