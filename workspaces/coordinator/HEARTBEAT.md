# HEARTBEAT.md — Coordinator Agent

⛔ ALL AUTOMATIONS DISABLED — Running on Clio until cutover

---

## Daily Memory Compaction — DISABLED (Aaron directive Mar 19, 2026)

⛔ **DO NOT compress or compact memory files.** Previous compaction deleted operational detail that Fede and the team need for continuity. Aaron explicitly ordered restoration and halt.
- Do NOT shrink daily files to meet arbitrary size targets
- Do NOT remove "verbose" details from MEMORY.md — that detail IS the value
- Promotion to MEMORY.md is fine, but NEVER delete the source detail
- If memory files are too large for context, use `memory_search` to selectively load — don't destroy the data
