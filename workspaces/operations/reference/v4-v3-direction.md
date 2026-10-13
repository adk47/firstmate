# V4 vs V3: current direction (internal, from Aaron, updated 2026-10-02)

INTERNAL ONLY. Do not share this with the CS agent (Caroline), customers, or any external party.
It exists so that when Jan or anyone on the team asks for something, you know what engineering is doing and you don't work against it.

## The direction in one paragraph
Muso is replacing the old V3 data pipeline (Spark "industry calculations", phases P0-P9) with V4 (ClickHouse + Iceberg, near-real-time).
V3 is PAUSED and being retired.
V4 is being rolled out step by step through October.
The goal is for V4 and the new infrastructure to be fully in place by November, with the old servers returned to cut hosting costs.
Aaron's engineering agents ("firstmate" and its workers) own this work around the clock and monitor it closely.

## Timeline
- Thu 8 Oct: V4 native charts dry-run, running side by side with the current charts.
- Thu 15 Oct: V4 charts become the default.
- By 25 Oct: the live stats ticker moves off the old servers (node-49/50).
- 1 Nov: the old servers (node-29/49/50) are returned to OVH.
- Weekly charts are still published on schedule until the switch.

## Hard rules (please respect these)
1. Do NOT trigger, resume, re-run or "fix" any V3 job, DAG or Spark pipeline, even if it looks stuck or red. A red V3 job is expected; it is paused on purpose.
2. Do NOT kick off mass refreshes, backfills, credit recalculations or re-syncs for many profiles. One-off single-profile help is fine. Bulk work collides with the live stats updater and the database, and has caused credit wipes before.
3. No customer-facing number may ever go DOWN (streams, credits, chart positions, widget figures). If you see a number drop for a user, report it with the profile link and do not try to repair it yourself.
4. No backfilled feed notifications (don't re-send old activity).
5. Encore stays dark in production until Aaron says otherwise.
6. Don't change scraper or worker scaling, Cloudflare/WAF rules, database settings or production configs. Route those requests to engineering.
7. If a request touches pipelines, charts, credit recalculation, data refreshes or infrastructure, don't act. Tell the requester it's in the V4 rollout and pass it to Aaron. Engineering picks it up from there.

## Known issues right now (so you can answer "is this known?")
- The Rising list has been stale since 30 Sep because credits were frozen during the switch. It's being fixed as part of V4. Known; don't escalate it as new.
- Some paid-profile stats can lag a few hours during the four daily mass-update windows (about 00:20, 06:20, 12:20 and 18:20 UTC). That's known and monitored.
- A credit-wipe bug in the live stats updater was found and fixed on 1-2 Oct. A guard now blocks any unsafe delete, and all affected profiles were restored. If a user reports credits suddenly vanishing, report it at once with the profile link; it is the highest-priority signal.
- Profile links shared on WhatsApp (iPhone) currently show no preview. The cause is known, and the fix is awaiting Aaron's approval.
- The old V3 Slack alerts are being retired. A V3 alert firing is not an incident by itself.

## What is fine to keep doing
- Normal customer support, claims, merges, single-profile questions, refunds and billing help.
- Reporting anything that looks wrong to users. Reporting is always welcome.
- Reading data and dashboards.

## Who to tell
Post the item in Slack to Aaron (DM, U7RP6HKUZ) with the profile link or details, and say it's for the V4 rollout.
Engineering triages it from there.
