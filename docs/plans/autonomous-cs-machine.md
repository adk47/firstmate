# Autonomous Customer Support: the self-healing, self-improving machine

**Status:** LIVING PLAN. Phase 0 authorized and in flight (2026-07-15, PR #691 enables the
improver + #692 builds the digest); Phases 1-4 remain gated per their one-way-door sign-offs
(section 4). Owner: Nick. Ratified by oracle; evidence-anchored to the live repo + node-8 timers.

**North star:** turn CS from "tell us what went wrong" into "fix it, help the customer, and feed
the product what to build" so that most tickets never need a human, and the ones that do arrive
pre-ranked for Jan. Every recurring ticket class is treated as a product bug to design out.

**One-line thesis:** we are not building this from zero. Most of the closing/notifying machine is
already live in production. The work is (a) fill the narrow real gaps, (b) turn on the
self-improving loop that is built-and-parked, and (c) push recurring ticket classes into
`web-credits-next` self-serve. "90%" is a joint hydra + product target, not a hydra-only cron.

---

## 1. What is ALREADY LIVE (verified, do not rebuild)

These automations run autonomously on node-8. The first five are systemd timers installed and
running `--apply` (`scripts/install-aux-units.sh`); `credit-verification-batch-4h` is the exception:
an isolated OpenClaw cron from `cron-jobs.json`, not a systemd unit. See each row's Mode and
Source columns for the exact runtime.

| Timer | Cadence | Mode | What it does | Source |
|---|---|---|---|---|
| `close-resolved-conversations` | every 6h | `--apply --notify` | closes Intercom convos when ALL linked ClickUp tickets resolved AND we spoke last; shadow-logs every close; posts summary to #cs_chats | `scripts/close-resolved-conversations.py`, install-aux-units.sh:319-351 |
| `resolve-notify` | 4x/day (02/08/14/20 UTC) | `--apply` | tells the customer "your request is sorted", which makes us we-spoke-last so the close batch then buries it | `scripts/resolve-notify.py`, :417-444 |
| `resolution-matcher` | daily 12:00 UTC | `--apply` | backtests shipped data-fixes against open convos per cited entity, notifies in a fixed message, closes, rolls up "your fixes closed N conversations" to Aaron | `scripts/resolution-matcher.py`, :473-501 |
| `close-merged-tickets` | daily 07:00 UTC | `--apply` | closes profile-merge ClickUp tickets whose merge already landed (matches merge route in action_log, avoiding the async-merge verification trap) | `scripts/dedup/sweeps/close-merged-tickets.sh`, :625-658 |
| `overdue-verification-notifier` | daily 09:00 UTC | `--apply` | proactively tells a customer when their Tier-1 verification ticket is past SLA | `scripts/overdue-verification-notifier.py`, :367-394 |
| `credit-verification-batch-4h` | every 4h | isolated agent turn | autonomous drain of the unverified-credits queue (~500/run), self-posts to #credit-verification | `cron-jobs.json` credit-verification block |

Notify/review layer already live: `support-email-triage-hourly` (classify support@ to #cs_chats),
`caroline-daily-review` + `caroline-weekly-rollup` (grade voice/leak/tools/sentiment + KB-gap
candidates), `systemic-data-issue-report-daily` (cluster >=2-user complaints to Aaron),
`stale-ticket-watchdog` (page ops on SLA breach).

**Caroline already resolves autonomously** (edge agent, event-driven on inbound Intercom, 7 gated
writes): claim own profile, verify catalog-corroborated credit, consolidate own duplicates, remove
credit, update order address, mint founder buy-back link, apply 50% retention + period-end cancel.
Every write is identity-corroborated via the Intercom contact email (server-derived, never an agent
param), capped per actor/day, audit-logged, and codex-health-gated.

### The design invariants that make this safe (do not violate)
- **"A customer still waiting is never closed."** Closes require we-spoke-last
  (`last_admin_reply_at > last_contact_reply_at`), never customer_last or never_replied.
  (`workspaces/support/SOUL.md:168`)
- **Caroline has NO close tool and NO Stripe.** Close authority and money-writes live on the main /
  operations gateway, deterministic, never on the customer-facing agent. This is doctrine, not an
  oversight: close-authority on the agent that talks to customers is how a model confabulates
  "resolved."
- **Every close path** is: deterministic gate + dry-run default + `--apply` gate + `--limit` ramp +
  shadow log + host guard.
- **Money gates fail CLOSED.** Refund execution stays ops/approval-tier ($500 hard-wall to Aaron,
  one-time-refund policy, no-paid-access-after-refund gate).

### Verified baseline (2026-07-15, read-only node-8 audit)
Denominator for the North Star metric. All five timers healthy, zero failures in last run.

| Sweep | Closes / activity, last 7d |
|---|---|
| close-resolved-conversations | ~285 Intercom conversation closes (1196 lifetime) |
| close-merged-tickets | 336+ ClickUp merge-ticket closes (journald floor) |
| dedup sweep (feeds close-merged) | 586 duplicate decisions (585 hard-dupe pairs) |
| resolve-notify | 549 candidates last run, 0 new to send (backlog already notified) |
| overdue-verification-notifier | 2 candidates, 0 overdue-new |
| resolution-matcher | ~0 acted (matches fixes but the tickets are already closed by then) |

Machine is closing ~600+ tickets/week (conversations + merge-tickets) with zero failures.
Finding: `resolution-matcher` yields ~0 (targets closed before it fires) - retune candidate,
not urgent. We still lack a live open-conversation count (needs an Intercom token); the ranked
digest (Phase 0.3) will surface it. Timestamp formats for future code: close-resolved + matcher
= epoch seconds; dedup + support-email = ISO-8601 Z.

---

## 2. The REAL gaps (what to build)

1. **Duplicate conversations** are not closed by anything today. Same customer opens 3 threads for
   one issue -> clutter, double-work.
2. **The unlinked open pile.** Every live sweeper keys off a ClickUp-ticket link or a shipped-fix
   match. Open conversations with NO linkage (Caroline could resolve now, or ops could resolve now,
   or genuinely needs-human) are not being proactively worked, only handled if the customer pings
   again.
3. **No single ranked "needs-human" queue for Jan.** Jan reads several digests and pulls ClickUp by
   hand. There is no one daily "here is what the machine could not close, ranked" surface.
4. **The self-improving loop is parked.** `caroline-autonomy-improver` (opens ONE PR/week improving
   `workspaces/support/**`, reviewer Nick, never-merges) exists but is `enabled:false` pending
   exactly this sign-off.
5. **The product-signal loop has no back half.** We cluster data issues to Aaron, but nothing ranks
   recurring ticket classes as `web-credits-next` self-serve features. The product gaps that
   generate the tickets are confirmed absent in that repo: profile MERGE (no UI, top-3 ticket),
   UNMERGE, REFUND self-serve, credit-verification STATUS dashboard, analytics REFRESH trigger,
   pending-credit visibility, duplicate-charge dispute UI.

---

## 3. Phased plan

Cadence principle: machine sweeps keep their own conservative timers (6h/daily). Only the
human-facing digest is a fixed daily rhythm. Jan cannot consume six digests a day.

### Phase 0 - reconcile reality + free wins (this week, Nick sign-off)
| # | Deliverable | Mechanism | Owner | Gate / sign-off | Success metric |
|---|---|---|---|---|---|
| 0.1 | **Live-state baseline audit** on node-8: confirm all timers active (`systemctl list-timers`), read shadow logs for closes/week + error rate. This is the denominator for the 90% goal. | read-only ssh audit | scout / hydra-operator | none (read-only) | a table: sweep -> cadence -> closes/week -> failures |
| 0.2 | **Enable `caroline-autonomy-improver`** (flip `enabled:false`->`true` in `cron-jobs.json`; keep `CAROLINE_IMPROVER_ALLOW_EDGE_PR` unset). Built to ship disabled pending this gate; edits confined to `workspaces/support/**`, ONE PR/week, reviewer Nick, never-merges. | openclaw cron config | implementer | **Nick** (the designed gate) | first improver PR reviewed within a week |
| 0.3 | **Needs-human ranked digest**: new operations openclaw cron (isolated, model on the allowlist or it silently fails), DAILY. Inventory open Intercom convos NOT owned by any live sweeper's state, bucket into {dup-candidate, resolvable-now, needs-customer-input, needs-human}, post ONE ranked Block Kit digest to #cs_chats. READ-ONLY, zero writes to Intercom. | openclaw cron + `skills-all/` skill | implementer | Nick | Jan stops pulling ClickUp by hand; residue trends down WoW |

### Phase 1 - duplicate-conversation sweep (shadow -> apply, ~2-3 weeks)
- New `scripts/close-duplicate-conversations.py`, modeled byte-for-byte on close-resolved's guard
  stack (dry-run default, `--apply`, `--limit` ramp, shadow log, host guard). Installed as a
  systemd timer via `install-aux-units.sh` (deterministic, no-LLM per the extension decision tree).
- Hard constraints: **same-customer-email only** (cross-customer "duplicates" rejected
  indefinitely), deterministic linkage (same customer + older thread we-spoke-last-or-never-engaged
  + newer thread active), close the OLDER with a pointer. **No LLM judgment in the close path.**
- **De-confliction invariant (top implementation risk):** must EXCLUDE any conversation already
  present in a sibling sweeper's state (`/var/lib/resolve-notify`, `/var/lib/resolution-matcher`,
  close shadow logs). Double-messaging a customer is the #1 way this plan hurts us.
- Owner: implementer (TDD, bats with openclaw/muso PATH-stubbed). Gate: >=2 weeks dry-run with Jan
  reviewing shadow candidates, then `--apply --limit 10` ramp. **Sign-off before `--apply`: Jan +
  Nick (one-way door).** Success: zero false-close reports; dup bucket in the digest -> ~0.

### Phase 2 - work the residue (ops-drain + Caroline re-engagement)
- **2.1 Ops-resolvable drain:** operations resolves the resolvable-now bucket via muso-cli
  (`--requester`, codex-health gate, caps, self-post summary), reusing the credit-verification-batch
  pattern. No new authority; uses writes ops already holds.
- **2.2 Re-engagement message:** fixed-constant (zero-interpolation) Intercom nudge for
  needs-customer-input; the customer's REPLY wakes Caroline through her normal inbound lane. We do
  NOT dispatch Caroline per-conversation (that risks the edge lane wedge; mitigations #616/#668 stay
  load-bearing). **Sign-off: Aaron on the message template (voice + SLA-honesty doctrine).**
- Success: %-of-inbound resolved with zero human touch, target 60-70% this phase.

### Phase 3 - product-signal loop (the road to 90%)
- New **monthly** "self-serve gap" report: a `skills-all/` skill (canonical only) + operations cron,
  reading the conversation corpus + weekly digest theme roll-ups, ranking ticket classes by
  volume x Caroline-unresolvable-rate: merge UI, unmerge, refund self-serve, credit-status
  dashboard, analytics-refresh, pending-credit visibility. Posts to a priority channel mentioning
  Aaron. Do NOT overload `systemic-data-issue-report-daily` (wrong cadence + audience).
- **Ownership boundary:** hydra EMITS the ranked signal; building the features is the
  `web-credits-next` team (Serhii / dev). Auto-filing issues/PRs into that repo is a one-way door
  under the standing no-PR-without-ask rule; humans convert the report to issues.
- **On "90%":** decomposes honestly. Caroline + sweeps + ops-drain gets ~60-70% of inbound. The last
  tranche is dominated by merge/unmerge/refund/status tickets that only PRODUCT self-serve removes.
  90% is a joint hydra + web-credits-next target, ~1-2 quarters after the top-3 self-serve features
  ship. Writing it any other way invites gaming the metric by closing harder instead of resolving
  better.

### Phase 4 - PARKED (not scheduled): refund autonomy
Refund execution stays ops / approval-tier. The refund-reconcile history (live dry-run killed
auto-cancel because goodwill was indistinguishable from exit) is direct evidence that auto-refund
logic misclassifies. Revisit only on Aaron's explicit ask, and only after Phase 2 metrics exist.

---

## 4. One-way doors (explicit human sign-off before shipping, in order)
1. Enable `caroline-autonomy-improver` -> **Nick** (the designed gate).
2. Duplicate-close `--apply` -> **Jan + Nick**, after >=2-week shadow review.
3. Any new customer-facing message template -> **Aaron** (voice + honesty doctrine).
4. Any new Caroline tool / authority: a close tool is **REJECTED**; anything money-adjacent -> Aaron.
5. Refund money-write autonomy -> **Aaron only; stays parked.**
6. Cross-customer duplicate closes and any LLM-judgment close path -> **rejected indefinitely**.
7. Automated writes (issues/PRs) into `web-credits-next` -> **human ask required.**

## 5. The metric that keeps us honest
Weekly: **AI-resolved / total inbound**, with **reopen-rate** as the honesty check. "Closed" is not
"resolved": count shadow-log closes AND reopens, or the sweeps inflate the number by burying live
customers. This metric is the denominator the Phase 0.1 baseline establishes.

## 6. Verification checklist the work is held against
1. No new component writes to a conversation owned by a sibling sweeper's state.
2. Every close path: deterministic gate + dry-run default + shadow log + `--limit` + host guard.
3. Caroline's tool surface unchanged (no close, no refunds, no proactive sweep).
4. All seven one-way doors have a recorded human sign-off before their `--apply` / enable.
5. Weekly metric exists: AI-resolved / total inbound, with reopen-rate.
6. Product-signal report ships as a `skills-all/` skill + ops cron; zero automated writes to
   `web-credits-next`.

## 7. Decisions log
- [x] **Plan home:** `docs/plans/` in-repo (versioned). (2026-07-15)
- [x] **Enable self-improving loop (Phase 0.2):** Nick signed off (2026-07-15); enabled via
      **PR #691** (`cron-jobs.json` `enabled:true`, `CAROLINE_IMPROVER_ALLOW_EDGE_PR` unset). Goes
      live on merge + deploy; first weekly PR fires Mon 11:30 Rome, scoped to `workspaces/support/**`,
      reviewer nsollazzo, never-merges. (one-way door #1: cleared)
- [x] **First build:** Phase 2.1 ops-drain DESIGN SPEC -> `docs/plans/cs-ops-drain-spec.md`.
      (2026-07-15)
- [ ] Risk appetite on duplicate-close: conservative same-customer-only (recommended) - confirm at
      Phase 1.
- [ ] Confirm product-signal loop feeds `web-credits-next` as a ranked report, humans convert to
      issues (no auto-PRs) - confirm at Phase 3.

## Appendix - source of truth
- Live timers: `scripts/install-aux-units.sh:309-658`
- Close logic: `scripts/close-resolved-conversations.py`, `scripts/resolution-matcher.py`,
  `scripts/resolve-notify.py`, `scripts/dedup/sweeps/close-merged-tickets.sh`
- Caroline: `workspaces/support/SOUL.md`, `workspaces/support/TOOLS.md`,
  `plugins/support-tools/src/index.ts`
- Parked loop: `cron-jobs.json` caroline-autonomy-improver block
- Product gaps: `web-credits-next` (settings/billing, roster/claim-modal); recurring classes in
  `workspaces/support/reference/common-issues.md`
