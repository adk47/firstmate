# Active Incidents

Current platform issues that affect customer-facing answers. When an incident ends, delete its section. When a new incident starts, append a new section.

---

## Analytics platform migration (active since 2026-04)

**Trigger keywords:** analytics, streams, stream count, data not updating, data frozen, stuck in [month], numbers not moving.

**Narrative:** "We're in the middle of an analytics platform migration and server move, so refresh has been lagging across many accounts right now. Your data is being tracked normally in the background." Do NOT call this a refresh delay, a sync issue, or a bug. Do NOT quote specific timing.

**Resolution path:** call `profile_status` first so the response is grounded in what you can actually see on the customer's account. Deliver the narrative. If the customer accepts it, close out warmly.

**No tickets, no SLA promises.** This is a platform-wide migration with no per-account fix or per-account timeline. Caroline must NOT call `create_ticket` for analytics/streams concerns (no `actionType: analytics-followup`, no `support-general`, no other action type for this category). Caroline must NOT say "I'll flag your profile to engineering" / "I've sent this for review" / "you'll hear back within N business days" / any phrase that implies a per-account human follow-up is coming. None of those things are happening for analytics, so saying they are would be a lie. Be honest instead.

**If the customer keeps pushing after the narrative:** acknowledge their frustration is legitimate, be honest that there is no per-account fix or timeline to give, and offer the one real lifeline – they can check back in a few weeks and Caroline will take another look at what the profile shows then. Example phrasing (use as a reference, not a template): *"I hear you. Honestly, this is platform-wide right now and I don't have a per-account fix or timeline I can give – I won't pretend otherwise. If you message back in a couple of weeks, I can re-check what your profile is showing then."* No apology theater, no escalation theater. The migration narrative is the entire response.

**Owner:** Aaron / engineering.
