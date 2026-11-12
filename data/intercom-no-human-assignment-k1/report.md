# Intercom: no human assignment by default (k1)

Captain, 2026-11-11: Jan must stop answering customers in Intercom; "Jan is saying 50-100
assignments are happening to him a day can you cut this to zero and have Caroline handle all of
them"; "remove standing rules to assign tickets to Jan vs. solving them with caroline".

All counts below were read from the Intercom API (v2.11), the edge gateway journal and the safety
ledger on 2026-11-11. Where something could not be measured it says so.

## The headline number

Assignments to Jan (admin `5465657`) per UTC day, every conversation updated in the last 15 days
(3,601 read, 0 unreadable):

| day | 10-27 | 10-28 | 10-29 | 10-30 | 10-31 | 11-01 | 11-02 | 11-03 | 11-04 | 11-05 | 11-06 | 11-07 | 11-08 | 11-09 | 11-10 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| events | 5 | 3 | 10 | 5 | 3 | 3 | 51 | 59 | 44 | 44 | 54 | 29 | 31 | 65 | 55 |

- **Before: mean 48 a day from 11-02 to 11-10 (range 29 to 65).** Jan's "50-100" is right at the
  low end. Before 11-02 it was 3 to 10 a day.
- **Who made them: 478 of 485 were made by our own plugin** posting as Caroline (`5763097`). 6 were
  Jan assigning to himself, 1 was Intercom's Operator. No other person received a single
  assignment in the window.
- **After: not yet measurable.** The rule change is in this branch and is not deployed. In the
  code, the number of paths that can assign a conversation to an admin other than Caroline goes
  from six to zero, and a CI gate keeps it there. The live number will read zero only after merge
  and deploy; section "Verify in 24 hours" gives the command.

The jump on 11-02 is the day the output guard went to enforce mode (first `output_guard` ledger row
2026-11-02T00:50Z).

### Status at 2026-11-12T02:05Z: merged, not live

The PR (https://github.com/Muso-AI/hydra/pull/1889) was merged at 2026-11-12T01:40Z. It is not
running. Read from node-8 at 02:02Z: the live edge config still has `defaultInboxId` set to Jan's
admin id and no `escalationTeamId`, the new policy module is not on the host, and the edge gateway
has not restarted since 2026-11-11T04:14Z. So the old rule is still assigning to Jan.

Hydra deploys once a day at 04:00 UTC (`.github/workflows/deploy.yml`), not on merge. The last two
scheduled deploys (11-10 and 11-11) were refused before changing anything: "a credit send tick
window is open (7200 tick-in-flight) and waiting it out would exceed 900s". The last deploy that
succeeded was 2026-11-09T23:09Z. If the 04:00Z run on 11-12 is refused the same way, this change
stays off until somebody dispatches a deploy outside a credit send window.

## Part 1: every mechanism that puts a conversation on a person

Jan said 540. It was 581 open at the first pull (2026-11-11 ~17:00Z) and 914 at 19:36Z
(mechanism M4 below). Both are explained, row by row.

| # | Mechanism | Where it is defined | Automatic | Of 581 | Of 914 | Became |
|---|---|---|---|---|---|---|
| M1 | **Output guard block.** Caroline's reply fails a guard rule; the plugin posts the hand-off line and assigns the thread to `defaultInboxId`. | `plugins/intercom/src/caroline-safety.ts` `guardOutbound`; `openclaw-edge.json` `defaultInboxId: "5465657"` | yes | 390 | 414 | Stays with Caroline. No assignment call, no person promised. |
| M2 | **Risk escalation.** A rule, the turn cap, a request for a person or the judge fires; the plugin files a ClickUp ticket, posts the farewell and assigns to `defaultInboxId`. | `plugins/intercom/src/escalation-action.ts` step 4, rules in `escalation.ts` | yes | ~121 with M2b | 34 | Still a human escalation, with its reason, to a TEAM queue. Never a person. |
| M2b | **Other plugin hand-offs**: restricted-account hold, legacy keyword escalation, reply dropped by the help-link gate, reasoning leak. Also guard blocks whose tag did not attach. Not split further: the journal only goes back 44 hours. | `plugins/intercom/src/channel.ts` (four call sites) | yes | (in the 121) | 118 | Help-link drop and reasoning leak stay with Caroline. Restricted and legacy escalate to the team queue with a reason. |
| M3 | **Stale assignment plus reopen.** Any conversation Jan ever held (64,477 closed) reopens ON him when the customer writes, and the plugin's live check then drops every customer message ("human assignee"). Includes his own bulk reassignment of 2026-03-31. | Intercom behaviour; `plugins/intercom/src/handler.ts` live check | yes | 56 | 334 (172 bulk, 138 self, 24 by another admin) | A human assignee silences Caroline only while that human acted in the last 72 h. Otherwise Caroline takes the thread back and answers. |
| M4 | **A script posting as Caroline reopens old threads on their old assignee.** The credit account-digest campaign replied into 312 long-closed conversations between 17:33Z and 18:25Z on 11-11. Each reopened on Jan. No assignment part is written. | `/root/digest.py` on node-8 (`credit-digest.timer`). Not in this repo. | yes | 0 | 312 (inside M3's rows) | The plugin now reclaims on that webhook. The sender itself is another lane's. |
| M5 | **Assigned at creation with no assignment part.** 13 inbound emails, `count_assignments` 0, admin already Jan. | Intercom side. Not readable by API. **Not identified.** | yes | 13 | 13 | See "One click in the Intercom UI". |
| M6 | **Operator `message_assignment`**: a reply to an outbound message sent in Jan's name returns to him. | Intercom outbound message sender | yes | 1 | 1 | Send outbound as Caroline. |

Checked and ruled out, with the evidence:

- **Round robin, load balancing, away-mode reassignment**: no admin has `away_mode_reassign`, every
  team has `admin_priority_level` null. Intercom's workspace default assignment (2,118
  `default_assignment` events in 14 days) lands on TEAM `2238258` "Muso.AI" with no admin. It never
  names a person.
- **SLA escalation**: no SLA is applied on any of the 581.
- **Fin**: `ai_agent_participated` is false on all 581.
- **Team inbox default assignee**: none of the five teams routes to a person. "Payments Team"
  (`7111794`) has Jan as its only member, and nothing assigned to it in the window.

### Why M1 fires: one rule is 85% of it

414 guard blocks in ten days. 352 of them (85%) are a single rule,
`contradict/fact_unverified:status_chase`: Caroline sends the approved "your request is in the
verification queue" line, no caller ever sets the `open_request` fact, so the guard fails closed.
The remaining 62 (about 6 a day) are real catches: a timeframe promise 21, a deletion promise 10,
and so on.

So the chain behind "a credit verification question went to Jan" is: hand-off-only doctrine for
credits, the customer chases, Caroline sends the approved status line, the guard blocks it for a
missing fact, the plugin assigns to `defaultInboxId`, and `defaultInboxId` was Jan. This branch cuts
the last two links. `caroline-read-state-tools-r1` sets the fact, which removes the block itself.

### What the customer got

The edge journal shows 168 customer replies dropped in 24 hours with
`live check: human assignee 5465657`. Over the 44.6 hours the journal holds, it is 234 dropped
replies across 129 conversations; 111 of those had been put on Jan by the plugin and never
answered by him. Of the 581, Jan had replied in 46.

## Part 2: Jan's queue moved to Caroline

Tool: `scripts/intercom-queue-reassign.py` (plan, apply, revert, verify). It writes an assignment
part and, where Jan had replied, one internal note. It cannot close, snooze, tag or message a
customer; tests pin that. Every move has a ledger row carrying the previous assignee, written
before the call.

Run `k1-20261111T193634Z` (19:36Z to 20:10Z), ledger `data/intercom-no-human-assignment-k1/reassign-ledger.jsonl`:

| | count |
|---|---|
| Open on Jan when the run pulled (19:36Z) | 914 |
| **Moved to Caroline, read back and verified** | **895** |
| Failed | 0 |
| Closed by the run | 0 (all 895 were open before and are open after) |
| Sent to a customer | 0 |
| Left in place for a named reason | 19 |

The 19 left on Jan:

| reason | count | why |
|---|---|---|
| `left_escalation_unread` | 8 | the plugin escalated it and the reason could not be read (no ticket reference in the thread, or the ticket has no reason field). Unreadable is not "safe to hand to the bot". |
| `left_explicit_escalation` | 6 | escalated for a reason that keeps a human seat: legal threat 5, fraud complaint 1 |
| `left_restricted` | 5 | banned or proof-review accounts (`restricted-accounts.ts`), which Caroline never answers |

These 19 move to the escalation team with `apply --escalation-team 7111842` once this branch is
deployed. Moving them before that would let the old plugin code answer a legal-threat thread.

**Mid-reply.** Jan had replied to the customer in 92 of the 895. Each of those got one internal
note (not visible to the customer) saying when he last replied and how to resume: assign it to
yourself and reply. 15 of the 92 are genuinely mid-reply, meaning he replied in the last 14 days.
Nothing was sent to any customer.

The other 20 plugin escalations (turn cap 11, asked for a person 8, cancel intent 1) went to
Caroline, and each still has its ClickUp ticket. That is a call I made: the 8 customers who asked
for a person had been waiting on Jan with no reply, and the instruction is that Jan comes out. If
those 8 should sit in the escalation queue instead, they are the ledger rows with mechanism
`risk_escalation`. Going forward a request for a person still escalates, to the team queue.

**It is already refilling, as expected.** A fresh read at 20:14Z, three minutes after the run
ended, shows 21 open on Jan: the 19 above plus 2 that the still-live old rule put there during the
run, both output-guard blocks. One of the two is a thread the run had just moved.

Revert: `python3 scripts/intercom-queue-reassign.py revert --ledger data/intercom-no-human-assignment-k1/reassign-ledger.jsonl`
(a thread somebody has moved since is left alone and reported).

**Caveat until this PR is deployed.** The live plugin still runs the old rule. A reassigned customer
who writes again gets an answer from Caroline, but if that answer trips the guard the thread goes
straight back to Jan with the "pulling in a teammate" line. So the queue will refill at roughly the
old rate until deploy. There is a one-line interim on the host that I did not apply, because it is
outside this lane's worktree and firstmate has told the sibling lane not to hand-edit the live
config: set `channels.intercom.accounts.default.defaultInboxId` to `""` in
`/root/.openclaw-edge/openclaw.json` (after `announce-legit-write.sh`) and restart the edge gateway.
Old code then leaves blocked threads Unassigned instead of on Jan. The next deploy overwrites it
with this branch's config.

**Not done, on purpose.** Caroline only answers when the customer writes. The moved threads are
now hers, but nobody has been sent anything. Re-running her over the waiting backlog is a bulk
customer send and belongs to a decision, not to a reassignment.

## Part 3: the rules, before and after

One module now decides who holds a conversation: `plugins/intercom/src/assignment-policy.ts`.

| Rule | Before | After |
|---|---|---|
| Blocked, dropped or leaked reply | hand-off line, assign to `defaultInboxId` (Jan) | fallback line that promises no person, no assignment, stays with Caroline |
| Escalation | assign to `defaultInboxId` (Jan), reason only in the ticket | `applyHandOff` refuses without a reason; goes to TEAM `escalationTeamId` with `type: "team"`; the reason is in the journal line |
| `defaultInboxId` | the hand-off target | retired, ignored, warned on at load, failed by CI |
| Human assignee | silences Caroline for ever | holds for 72 h after the human's last action (`humanHoldHours`); then Caroline reclaims |
| Assignment webhooks during an escalation | unassign flipped the thread back to the bot | only an assignment TO Caroline ends an escalation |
| A reply posted as Caroline by another script | reopens on the old assignee | reclaimed for Caroline |

Enforcement: `scripts/check-intercom-no-personal-assignee.sh` in PR Validation fails on a
non-empty `defaultInboxId`, on a person's or the bot's id as `escalationTeamId`, on
`defaultInboxId` read anywhere in plugin code, and on any use of `assignConversation` outside the
policy module (a call, a computed access, an alias, the name built from pieces, a raw assignment
part). 32 bats cases. Plugin suite: 1,891 tests pass.

Added after QA review of the PR. A text scan can be dodged, so the rule is also enforced at
runtime: every client refuses an admin assignee other than "0" or the acting bot before any
request is made. And no escalation outcome is taken from what the assignment requests answered,
accepted or not: the conversation is always read back, and the escalation reports `failed` while
any admin, the bot included, holds it, when it sits in another team, or when it cannot be read.

**The escalation path still exists.** A request for a person, a legal threat, a security incident,
an abuse report, a refund or cancel dispute, the turn cap and a restricted account all still leave
Caroline, each with its reason, plus the ClickUp ticket and the Slack line they had before. Measured
volume: 8 in 44.6 hours, so 4 to 5 a day.

**Config in this branch:** `escalationTeamId: "7111842"` ("General team", no members),
`humanHoldHours: 72`.

One thing I caught before it shipped: team `7111842` is not empty. It already holds 29,278
conversations, 12,791 of them closed with no admin. A rule of "in the escalation team means held"
would have silenced Caroline on each of those the next time the customer wrote. The hold therefore
needs evidence of an escalation (session state, or the bot's own team-assignment part in the
thread), not team membership.

**New customer wording, one line, needs the copy owner's yes.** The blocked-reply fallback was the
hand-off line, which is false once nobody is assigned. It is now bank entry `ai_queue_fallback`:
"I want to get this right for you. Could you tell me a little more about what you need help with?"
It promises no person, no outcome and no date, and it asks for the one thing that wakes Caroline.
The limit: a customer whose question keeps tripping the guard will see it more than once, until the
turn cap (14) escalates them with a reason. Regenerating the reply instead of falling back is the
real fix and belongs in k2's fix loop.

### One click in the Intercom UI (cannot be changed by API)

1. **Who staffs escalations. Captain decision.** Settings > Teammates > Teams > "General team":
   add whoever takes the three human seats (conflicts, hold-list identities, declines). With no
   members, an escalated thread waits there with a ticket and a Slack line and nobody's inbox
   shows it. Not Jan personally. A dedicated team named "Escalations" would be cleaner; if one is
   created, put its id in `escalationTeamId`.
2. **M5, 13 emails assigned to Jan at creation.** I could not read which setting does this. The
   places it can live: Settings > Helpdesk > Assignments, and any Workflow with the action "Assign
   to: Jan Delmo". The target value is "Assign to: Caroline". A likely cause, unverified, is a
   customer replying to an email Jan sent from Intercom.
3. **"Payments Team" has Jan as its only member.** Nothing routed to it in the window. Remove him
   or leave it; it is not a live source today.

### Unverified until the first live escalation

Intercom's reference confirms `assignee_id` may be a team id. It does not show the `type: "team"`
value in the page I could read. Every escalation is read back, whatever Intercom answered: it is
reported Unassigned only when the read shows no admin and no team, and `failed` when somebody holds
it or it cannot be read. If Intercom rejects the team value the journal prints
`escalation team assign FAILED`. Check the first escalation after deploy for
`[intercom:assignment] escalated conv=<id> → team:7111842`.

The read-back itself is also unverified live. It needs `admin_assignee_id` and `team_assignee_id`
in Intercom's answer to `GET /conversations/{id}`. If either is ever absent, every escalation
reports `failed` and alerts, although the conversation was moved. That is the safe direction, and
the same first escalation shows it.

## Standing rules in OpenClaw: what was found and what each became

Caroline's workspace is `workspaces/support/`. Her written doctrine never assigns in Intercom; it
routes to a ClickUp ticket and tells the customer a person is coming. The assignment to Jan was the
config key and the plugin, above.

| Rule, quoted | Where | Became |
|---|---|---|
| `"defaultInboxId": "5465657"` | `openclaw-edge.json`, and live `/root/.openclaw-edge/openclaw.json` | removed; `escalationTeamId` + `humanHoldHours` |
| "let me flag this for them and someone will be in touch soon" | `SOUL.md` `human_review` row; `reference/common-issues.md` | "I've flagged this for our team. You'll hear from us in this conversation and by email." (already approved wording; "soon" was itself a guard violation) |
| "I've passed you over to one of our teammates" and "The teammate will take over." | `skills/action-request/SKILL.md` Human Handoff; `skills/order-fulfillment/SKILL.md` step 0 | a ticket is filed with the reason, the conversation stays with Caroline, she never says a person has taken over |
| `frustration_detected` and `loop_detected` hand off to a teammate | `skills/action-request/SKILL.md` | ticket the reason and keep helping |
| "Aaron or Jan must approve" | `skills/action-request/SKILL.md` approval tiers | "Leadership must approve"; no named person |
| "helps Operations/Jan understand" | `skills/refund-retention/SKILL.md` | "Operations" |
| Analytics: "file `analytics-followup` + escalation language" for any data question | `AGENTS.md` rule 5, `SOUL.md`, `reference/common-issues.md` | freshness questions are answered by Caroline from `data_freshness`; a ticket only when the data is genuinely off |
| "A team member will follow up." | `plugins/support-tools/src/tools/profile-analytics-status.ts` deny text | removed |
| "assigned to the configured human escalation inbox (`defaultInboxId`) so a teammate picks it up" | `skills-all/muso-intercom/SKILL.md` | Caroline is the default assignee; escalation goes to the team queue |
| (new) "Who holds the conversation" | `workspaces/support/AGENTS.md` | you do; a ticket is not a hand-off; nothing routes to a named person |

Found and left, with the reason:

- **"I'm pulling in a teammate to take this from here."** on credits, documents, claims and merges
  (`AGENTS.md`, `skills/verification-handoff/SKILL.md`, `reference/common-issues.md`,
  `plugins/intercom/src/merge-reply-guard.ts`). This is the credit-verification rule Aaron named.
  It is `caroline-read-state-tools-r1`'s: that lane is giving Caroline the four read tools and the
  guard rule that refuses a person-promise without an assignment. Two lanes editing the same lines
  would collide. After this branch the line no longer puts anything on Jan; it is still untrue to
  the customer until r1 lands.
- `SOUL.md` "Owner: Jan (Operations lead)", `USER.md`, `MEMORY.md`: ownership notes, not routing.
- `SOUL.md` "A credit removal is never an agent write: the owner does it in the app, or Jan or
  Nick in their own session": the removal authority rule (core-backend #10310), not an assignment.
- "flag it for our team" in `reference/faq.md` and `reference/founding-member.md`: a ticket.
- `riskAssessment.turnCountHardCap: 14`: about one escalation a day for nothing but length. The
  weakest remaining reason for a human. Left because it is now the backstop for a guard loop.

## Part 4: analytics questions (164 in 30 days, 85% told a person is coming)

"Where is my request" is r1's. This lane built the analytics read.

**Built:** `profile_analytics_status` now returns `data_freshness`:
`is_current`, `last_updated_at`, `age_hours`, `stale_after_hours`, `last_run` (date, tracks in
progress, updated, total) and a named `source`. Source: core admin API
`GET /api/v3/admin/profile/{id}/analytics-status`, read live in the call. `is_current` uses the
backend's own threshold, and is null when either number is missing. The entitlement gate is
unchanged: a customer who may not see analytics gets none of it. 7 new tests.

**Designed, not built, because the source is not reachable:** "is there a known pipeline issue
affecting this user". The only machine record is the V4 staleness sentinel's finding ledger in the
platform-data-processing lane; nothing on the edge gateway can read it. The tool returns
`known_issue: { measured: false }` and Caroline is told not to say there is or is not one. What is
needed: one read endpoint over that ledger keyed by profile, then one field here. Also missing from
the source: per-platform last-update times.

## Verify in 24 hours that the queue is not refilling

After merge and deploy:

```
python3 scripts/intercom-queue-reassign.py verify --from-admin 5465657 --hours 24
```

Exit 0 and `"verdict": "ZERO"` means no conversation was assigned to Jan by anyone but Jan. It also
prints how many are open on him. An unreadable conversation makes it `UNMEASURED`, not zero.

Journal, same window:

```
journalctl -u openclaw-gateway-edge --since -24h | grep -c "live check: human assignee 5465657"   # was 168
journalctl -u openclaw-gateway-edge --since -24h | grep -c "reclaim conv="                        # stale threads taken back
journalctl -u openclaw-gateway-edge --since -24h | grep "\[intercom:assignment\] escalated"       # each with its reason
```

The standing metric and the page are `caroline-monitor-and-fixloop-k2`'s. The definitions it needs
are in `metric-contract.md` next to this file: assignment events to any person (pages above 0) and
open-on-person (pages when it rises, which is the only number that sees M4).

## Other things seen

- `credit-thread-reply-tick.service` on node-8 has failed on every run since 17:59Z on 11-11:
  `FileNotFoundError: '/tmp/.ictk2'`. It is the unit that replies in-thread to customers who wrote
  last. Not this lane's; not touched.
- `/root/digest.py` (M4) should assign a conversation to Caroline before it replies into it. Jan
  has 64,477 closed conversations; every campaign run can reopen more. The plugin-side reclaim in
  this branch covers it once deployed.
- The legacy escalation path posts `fallbackAcknowledgement` ("...will get back to you shortly").
  It is unreachable while `riskAssessment.enabled` is true. Left alone.
- `workspaces/support/SOUL.md` is at 49,692 of 50,000 characters. The next lane to add to it will
  hit the cap.
