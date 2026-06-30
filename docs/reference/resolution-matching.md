# Resolution matching & closing — closing the loop on systemic data issues

> Added 2026-06-29 for Aaron's ask: *"nothing is checking to see if tickets are
> being closed with what I'm working on ... monitor for fixes and report back to
> users status etc and helps close tickets. Resolution matching and closing."*

## The gap this fills

Hydra had a mature **detection** path and a mature **status-flip → notify →
close** path, but nothing connected a *shipped fix* to the tickets it resolved
(except the single profile-merge case). Concretely:

- `report-systemic-data-issues` (cron `systemic-data-issue-report-daily`) pages
  Aaron daily with the *symptom* — "N users hit the same data problem." It is
  **detection only**: nothing then watches for the fix or tells those users.
- `resolve-notify.py` / `close-resolved-conversations.py` only fire when a human
  flips a ClickUp ticket to *resolved*. When Aaron fixes the underlying **data**
  (not a ticket status), those tickets/convs just go quiet.
- `close-merged-tickets.sh` is the one fix-driven closer, hardwired to
  `/api/v3/admin/profiles/merge`.

`resolution-matcher.py` generalizes the merge-closer to the systemic-issue case.

## The closed loop

```
  Intercom complaints
        │  (daily 06:00 Europe/Rome)
        ▼
  intercom-data-complaint-watchdog.py --report   ── pages Aaron (symptom)
        │                                            AND now appends each paged
        │                                            cluster to the FEED ↓
        ▼
  /var/lib/resolution-matcher/cluster-feed.jsonl   (append-only; issue_slug,
        │                                            per-member conv_id, email,
        │                                            cites, age_hours, paged_at)
        ▼
  resolution-matcher.py --apply   (daily 12:00 UTC, resolution-matcher.timer)
        │
        ├─ DATA-BACKTEST: for each open member, extract the entity UUID(s) they
        │   cited and ask action_log (Trino, via `muso query`): did any admin
        │   DATA-FIX route touch that exact id, AS THE PATH TARGET, AFTER they
        │   reported? The id must appear in the request ROUTE (the primary target,
        │   e.g. /api/v3/admin/profile/<id>/credits) — NOT merely somewhere in
        │   requestdata, which would also match rows that only REFERENCE the entity
        │   (a merge where the cited profile is the absorbed loser, or a claim
        │   DENIAL carrying the id). Merge is intentionally excluded (id is in the
        │   body, and close-merged-tickets.sh already owns merge tickets); claiming
        │   /identity-resolution are excluded pending a node-8 outcome gate.
        │
        ├─ NOTIFY: Caroline-voice, soft "we made an update — please verify" note
        │   (fixed constant, zero interpolation → zero leak surface). Soft, not
        │   "it's fixed", because the signal is "an admin touched it", not a
        │   positive source-vs-Muso re-check. Invites a reply so a wrong match
        │   self-corrects.
        │
        ├─ CLOSE: notifying makes us "spoke last" → close the Intercom conv +
        │   best-effort flip any linked ClickUp ticket to resolved. Reversible
        │   (shadow log: /var/log/resolution-matcher-shadow.jsonl).
        │
        └─ ROLL UP TO AARON: "your fixes closed N convs across M issues",
            attributed to the action_log row (route + who shipped it + when).
            → the priority channel (same place the detection report lands).
```

## Safety model (why unattended `--apply` is safe)

Per Aaron, the timer ships **enabled + `--apply`** ("go live immediately"). That
does **not** drop the guard stack every sibling outbound script carries — those
are what make an unattended `--apply` safe, not a dry-run gate:

- **host guard** — refuses anywhere but `ovh-node-8`.
- **cold start** — the first `--apply` run (no state) seeds every current member
  as already-seen and sends **nothing**, returning before the backtest. So a
  fresh deploy never messages the existing backlog. One-run anti-blast seed, not
  a dry-run window. (It logs a seeded *count* only — it does not run the backtest
  or post a roll-up, so it is not a per-match preview; use a manual dry-run on
  node-8 for that.)
- **circuit breaker** — a large matched set on a freshly-written state file
  (wipe / feed bug) aborts and pages instead of blasting. Keys on the default
  `RESOLUTION_MATCHER_MAX` so `--limit` cannot disarm it.
- **per-conversation dedup** — `conv:<id>` in state → at most one message ever.
- **email cross-check** — a fresh `GET /conversations/{id}` right before sending;
  the conv `source.author.email` must equal the feed member's email (fail closed
  on absent/mismatch). The wrong-customer guard.
- **suppression** — never reopen closed/snoozed, never speak over a human
  assignee / last human reply, never touch a social/abuse-tagged conv.
- **per-run cap**, **atomic state writes**, **reversible shadow log**, and a
  **query error fails closed** (that member stays open).

Dry-run by default; `--apply` is the only path that messages/closes/writes state.

## Fix routes (validated on node-8, 2026-06-30)

What counts as a "fix" is a **constant, reviewed predicate set** in code
(`_FIX_ROUTE_PREDICATES`), not env config — the route set is safety-critical and
customer-facing, so it lives where it's reviewed (and that removes any
SQL-injection surface from routes). Both predicates require the cited UUID to also
appear in the route path (`route LIKE '%<uuid>%'`):

1. **credit add/remove** — `route LIKE '%/credits%'` — matches both
   `/api/v3/admin/track/{uuid}/profile/{uuid}/credits` and
   `/api/v3/admin/profile/{uuid}/credits`. The dominant credit-misattribution fix.
2. **bare profile-data edit** — `regexp_like(route, '^/api/v3/admin/profile/[0-9a-fA-F-]{36}([?]|$)')`
   — PUT/DELETE on the profile itself (name/image/fields), NOT its sub-resources.

Live `action_log` (90d) confirmed: these cover **2576** writes (2516 credit + 60
profile-edit) and **drop ~2000** noise writes under the same prefixes — `/cache`
clears, `/capture`, `/analytics-sources`, `/encore-assets/generate`,
`/playlist/regenerate` — which touch the entity without fixing the reported issue.
`/api/v3/admin/profiles/merge` matches 0 (id is in the body; merge tickets are
owned by `close-merged-tickets.sh`). Attribution reads the top-level **`email`**
column (the admin actor, e.g. `jan@muso.ai`) — validated that
`requestdata.requester` is empty on these routes. To add a route kind (or claiming
/identity-resolution behind an approve/deny gate), edit `_FIX_ROUTE_PREDICATES`
(a reviewed code change) — there is no route env knob.

**Before go-live**, run a dry-run on node-8 to eyeball the matched set:

```bash
set -a; . /etc/openclaw/shared.env; . /etc/openclaw/edge.env; set +a
python3 /opt/hydra/scripts/resolution-matcher.py        # dry-run preview
```

The first **live** run then cold-starts (seeds, sends 0) as a one-run anti-blast
guard before run #2 acts.

## Files

| Path | Role |
|---|---|
| `scripts/resolution-matcher.py` | the matcher (backtest → notify → close → roll-up) |
| `scripts/intercom-data-complaint-watchdog.py` | `--report` now also appends the cluster feed |
| `scripts/install-aux-units.sh` | installs `resolution-matcher.timer` (daily 12:00 UTC) |
| `tests/test_resolution_matcher.py` | pure-logic + main()-flow safety tests |
| `scripts/tests/resolution-matcher.bats` | CLI-boundary tests (env/host guard, cold start) |

## Tunables (env)

`RESOLUTION_MATCHER_MAX` (15), `RESOLUTION_LOOKBACK_DAYS` (60),
`RESOLUTION_SUMMARY_CHANNEL` (C0BBTAVP44X), `RESOLUTION_FEED_PATH`,
`RESOLUTION_STATE_PATH`. Full list in the `resolution-matcher.py` docstring. (The
fix-route set is NOT an env knob — it's `_FIX_ROUTE_PREDICATES` in code.)

## Known follow-ons (deliberately out of v1)

- **PR/deploy as a standalone trigger.** v1 attributes the fix via the
  `action_log` route + requester (precise), not a GitHub PR guess. Correlating a
  merged PR to specific customer tickets is too low-precision to auto-message on;
  wire it as corroboration only if wanted.
- **Live source-vs-Muso re-verification** per noun (credits/streams/...) would
  let the message assert "it's fixed" instead of "please verify". Higher
  precision, per-noun logic — a follow-on.
- **Shared library.** The Intercom search / suppression / `_ticket_resolved` /
  Slack-summary helpers are now duplicated across `resolve-notify.py`,
  `close-resolved-conversations.py`, `notify-merged-customers.py`, and this
  script (the codebase's existing "vendored twin" convention). Worth extracting
  to `scripts/lib/` once a fifth consumer appears — left as a separate, reviewed
  refactor so this change stays surgical.
```
