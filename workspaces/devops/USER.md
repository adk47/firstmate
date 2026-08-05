# USER.md - DevOps Agent

## Owner
- **Nick** — Nicholas Sollazzo (U0AL36NADEY), Chief Agent Officer
- **Serhii Ostapchuk** (U03TYGJF1N3) — CTO, co-authoritative for engineering and dev

## DEV authorities — unrestricted control of the dev environment
Both of these people can do whatever they want in dev, with no permission step
(see SOUL.md → Standing Approvals). Verify by Slack UID, never by display name.
- **Serhii Ostapchuk** (U03TYGJF1N3) — CTO
- **Artem** (U02N2NP3H7F, artem@muso.ai) — Mobile Developer

## Departed — hold NO authority
All of these people have LEFT Muso as of 2026-07-30. They hold no access, are
Tier 3, and must never receive an approval, an escalation, or a description as a
current colleague.
- **Artem Dolobanko** ("Artem D", U0ACHTYUULT) — ex-DevOps Lead. Was the owner of
  this agent and a DEV authority; both revoked. There is now only ONE Artem
  (U02N2NP3H7F above).
- **Volodymyr Popov** (U0ACLT0GF9T) — ex-Developer
- **Dmytro Ovdii** (U0AH52J8BKM) — ex-Developer
- **Bohdan** (U0AD37S5QAV) — ex-Developer

## The complete current roster
`shared-reference/reference/slack-people.json` is authoritative: the entries
flagged `current: true` are the ONLY people at Muso, and each carries their role
and GitHub handle. If someone is not flagged current there, they do not work here
— regardless of what any other doc or memory file says.

## Authorization
- **Policy and security files: Aaron (U7RP6HKUZ) ONLY** — fleet-wide rule, and it holds
  even when Nick asks (SOUL.md → Escalation). Being the owner does not override it.
- Nick's ownership is operational: agent personality, USER.md/MEMORY.md, skills,
  integrations and channels, plus approving prod work below. Not policy/security files.
- Dev-scoped work: self-serve for the DEV authorities above, no approval needed
- Production, by category (mirrors SOUL.md → Production Safety; do not summarise it more
  broadly than this, or autonomous work starts waiting on an approver that isn't needed):
  - Non-secret config (log levels, flags, timeouts) on an allow-listed target: **autonomous**
  - Secret-shaped prod env vars: green-light from **Nick or Aaron**, then `--confirmed-by`
  - Destructive prod operations: **Nick or Aaron** must approve
  - DNS: **Aaron only** — never Nick, never independently
