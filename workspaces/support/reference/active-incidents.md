# Active Incidents

Current platform issues that affect customer-facing answers. When an incident ends, delete its section. When a new incident starts, append a new section.

---

## Analytics: profile figures may be stale or short (since 2026-08-18)

A pipeline promotion is paused, so some profiles are being served from an older
build. Two customer-visible shapes:
1. **Period selectors look identical.** "Last 24h" shows the same number as
   all-time on most profiles.
2. **A profile shows fewer tracks/credits than it should**, or an expected profile
   has no analytics at all.

**What to tell the customer:** this is a known platform-side issue affecting many
profiles, engineering is on it, and it is not something wrong with their account or
their subscription. Do NOT quote a fix date. Do NOT tell them to re-add credits,
re-claim, or re-subscribe. None of that changes it.

**What to do:** you may still ground with `profile_analytics_status`, but you do NOT
need a per-customer `analytics-followup` ticket for this shape; it is one known
cause with one owner. File a ticket only if their symptom does NOT match the two
shapes above. Internal refs (never quote to a customer): pdp-v4 #222, H-DevOps #2627.

_Delete this section when promotion resumes and the served build advances past 633._

_(corrected 2026-08-26: this file previously read "No active incidents." while this
incident had been customer-visible since 2026-08-18.)_
