# Jan's five summarize/resolve asks, 2026-11-11 — what actually happened

Task `jan-intercom-5-answers-j1`. All reads below are read-only. Nothing was posted to
Slack, nothing was sent to a customer, and no credit, profile or ticket was changed by this
task. Customers are named by conversation id and profile id only.

## Finding

Jan was answered on all five asks, in thread, within 2 to 4 minutes each. The Ops channel
root does not show thread replies, so a reader who is not Jan sees his five asks sitting
between the bot's batch posts with nothing under them, and would reasonably conclude he
was ignored. The perceived silence is a visibility problem in how the Ops channel
renders, not a response failure. It will recur: the next outside reader will see the same
thing and escalate again.

**Recommendation (one, not implemented in this task).** Send the bot's first answer to a
staff ask to the channel as well as the thread (Slack `reply_broadcast: true` on the
threaded `chat.postMessage`); follow-ups stay thread-only. The answer then shows at the
root, labelled as a reply to Jan's message, and still hangs off the ask. An unthreaded
answer loses that link, and a per-batch summary post leaves the reader to match it up. Where it would go:

- Coded router path: `scripts/ops_intake/slack.py:52-61` (`post_message` sets
  `thread_ts` only). One key. That router is not intercepting today (see the owner section above).
- Agent-turn path, which produced today's answers: the openclaw Slack channel with
  `replyToMode: "all"` (`openclaw-main.json:628`). `reply_broadcast` appears nowhere in
  this repo, and I did not check whether openclaw can broadcast a thread reply.

Context from firstmate (inbox 002, 17:55Z), not verified by this task: Jan's actual
complaint is the number of conversations assigned to him to answer (50 to 100 a day),
not these five threads. Section 2 is consistent with that: all five end with a step only
he or Nick can perform.

## Needs an owner's sign-off: the ops-intake router is not intercepting Ops asks on node-8

**Owner: firstmate lane `jan-asks-intake-router-j2`** (named as the router's owner in
`docs/support/ops-intake-router.md:4`). A fix already exists and is not shipped: branch
`fm/ops-intake-before-dispatch-j3`, whose fix commit `93479eb9` (authored
2026-11-05 21:04 -0500, i.e. 2026-11-06T02:04Z) is "register before_dispatch, the
hook that actually fires", plus follow-up commits from that branch's own
no-mistakes run. At 09:55Z on 11-12 it had no PR on
GitHub; it has an open PR, https://github.com/Muso-AI/hydra/pull/1915, checked
15:36Z on 11-13 (unmerged), and had been in no-mistakes run
`01M77JTM34M7SCGT8GE8J3FHDM` at the review step. The
router has therefore been dead in production for at least the week since that commit
was written. Code owner of `plugins/` and `scripts/` per `CODEOWNERS` is `@adk47`.

Every message on the `operations` Slack account is supposed to be claimed by
`plugins/ops-intake` and answered by code before any agent turn. On 11-11 it claimed
none: the ask register has 0 rows while Jan made at least 7 asks. So Ops asks run as
free-form agent turns. On Jan's five that meant four attempted credit approvals (the
backend gate refused all four, nothing changed) and hand-composed replies to two
customers.

The cause I did not verify myself. That commit's explanation is that openclaw 2026.8.35
calls `inbound_claim` only for a plugin that owns the conversation binding, which this
plugin does not, so the handler never runs. It fits what I measured: the plugin is
enabled, installed and silent, and the installed build registers `inbound_claim` only
(0 occurrences of `before_dispatch`). Evidence and limits are in section 3.

Done means: that branch is merged and deployed, and one row lands in `ops_asks` for a
real ask in `C0APB2CMM7C`. Until then the backend approval gate is the only control
between an Ops ask and a credit approval.

## 1. The premise is wrong: Jan was answered on all five

The task said Jan asked five times and got no answer. Slack says otherwise.
Source: `conversations.replies` on `C0APB2CMM7C` with the operations bot token, read
17:20Z and again 17:33Z. Jan's "11:00 to 11:25" is 16:00 to 16:25Z.

| # | Conversation | Jan asked (Z) | First bot answer (Z) | Lag | Thread replies | Root ts |
|---|---|---|---|---|---|---|
| 1 | 215476530103259 | 16:00:37 | 16:02:54 | 2m17s | 9 | `1794412837.905679` |
| 2 | 215476692820441 | 16:04:12 | 16:07:35 | 3m23s | 9 | `1794413052.319539` |
| 3 | 215476700995903 | 16:21:14 | 16:24:16 | 3m02s | 3 | `1794414074.859209` |
| 4 | 215476584423897 | 16:24:34 | 16:27:17 | 2m43s | 7 | `1794414274.922989` |
| 5 | 215476639942446 | 16:25:15 | 16:28:07 | 2m52s | 3 | `1794414315.763369` |

Jan read the answers: he followed up inside all five threads ("do the suggested
resolution", "can you check it from a verifiable published credit?", and so on) and the
bot replied each time.

**Why it looked like silence.** Every answer is a thread reply. The channel root shows
only Jan's five messages between bot posts: `credit-trust-decide <id>: 500 rows reviewed`
every 10 to 15 minutes, two raw `stdout: NO_REPLY stderr: [model-chain] ...` dumps
(14:46Z, 15:46Z) and a CREDIT-AUDIT ALERT (16:49Z). Anyone reading the channel without
opening threads sees five asks and no answers.

**What I did not do, and why.** Firstmate decided at 17:55Z (inbox 002, closing
`[key=jan5-post-or-not]`): do not post. I did not post five more blocks as the Ops bot. The
summaries and states are already in the threads, Jan is mid-conversation in them, and the
agent session behind the bot would have no record of a message I posted under its name,
so a reply from Jan to my block would land on an agent that never wrote it. The blocks
drafted in section 4 stay as a record of the open step on each conversation.

## 2. What is still open: none of the five is resolved

Every thread ends at "a named human has to do this" with no name on it. Per
`docs/credit-verification/credit-retro-r1.md:41` the named humans are Nick or Jan, from
their own login. Three customers (#1, #2, #5) have had no reply at all in these
conversations since their last message.

State source for all five: Trino replica `postgresql_core.public.credit_requests`
(`deletedat IS NULL`), read 17:20 to 17:30Z 2026-11-11. Identity: Intercom `external_id`
matched to `users.neptuneprofessionalid`. UVN = `user_verification_needed`.

| # | Open requests (verified) | Untouched since | Last word to the customer |
|---|---|---|---|
| 1 | none open; profile `11c9e78d` has 1 request, approved 2026-07-17; none on `00992bba` | n/a | none in this conversation since it opened 10-23 |
| 2 | 2 UVN: "MDS" `d8e714cf`, "Locked In" `37a30bbd` (profile `7fcf02c2`, 218 approved) | 11-04 01:39Z | 11-04 03:08Z hand-off line; he asked for a human at 03:07Z |
| 3 | 31: personal `2b730586` 9 UVN + 1 unverified (410 approved); studio `fd06caaa` 10 UVN + 11 unverified (372 approved) | personal 11-10 14:23Z; studio UVN 10-28 | 11-11 16:31Z bot reply: nothing needs resending |
| 4 | 13 UVN, all created 10-27 21:24Z (profile `6ea0b385`, 943 approved) | 10-27 21:57Z | 11-11 16:35Z bot reply: 13 still in review |
| 5 | 3 UVN: Arbol `09b25a9c`, Prima di Colombo `7be154dd`, Pensare come i pesci `bfc9f279` (profile `b7124387`) | 11-03 18:27Z | 11-04 hand-off line; nothing since |

Not verified by me:

- **#1** That the profile merge is complete and that both "Insomnia" tracks still exist.
  Only the bot's Intercom notes (16:09Z, 16:22Z) say so. A profile read on `00992bba` and
  a track read on `5faae9a9` and `c400e00a` would settle it.
- **#1** The bot's 16:21Z claim that it updated the customer in the related conversation
  215476530103234. I did not read that conversation.
- **#3, #4** What the attached screenshots and documents show. I read the conversation
  text and the bot's notes, not the attachments.
- **#2** A different profile (`2db0aaf9`) holds approved Mixing and Mastering on a track
  titled "Locked In". The title is common; I did not confirm it is the same recording.

## 3. The ops-intake router: evidence and limits

Summary and owner are in the owner section at the top. Read on node-8 at 09:48 to 09:52Z
2026-11-12; the first two rows were also true at 17:33Z on 11-11.

| Measured | Source |
|---|---|
| `ops_asks` 0 rows, `ops_ask_events` 0 rows; file last written 11-06 06:40Z. It is the only `asks.sqlite` on the host and the daemon has no `OPS_INTAKE_*` override. | `/var/lib/hydra/ops-intake/asks.sqlite` (opened read-only); `/proc/<gateway pid>/environ` |
| Jan made at least 7 asks in `C0APB2CMM7C` on 11-11 (five at 16:00 to 16:25Z, 17:11Z, 17:28Z). The router's `claim` step writes one row per inbound ask before anything else. | Slack `conversations.replies`; `scripts/ops_intake/router.py:737` (`store.add_ask`) -> `scripts/ops_intake/store.py:195-199` (`INSERT INTO ops_asks ... ON CONFLICT DO NOTHING`) |
| No line containing `ops-intake` or `ops_intake` anywhere in the retained main-gateway journal (starts 2026-11-10 02:43Z). The plugin's error paths log `[ops-intake] ...` (`index.ts:144-344`). | `journalctl -u openclaw-gateway-main.service` |
| The gateway's own startup line at all three starts in that journal (11-11 02:31Z, 11-11 04:15Z, 11-12 02:32Z) reads `7 plugins: browser, codex, lobster, memory-core, memory-wiki, slack, support-tools`. `ops-intake` is not in it. | same journal, `http server listening` |
| The plugin is configured and installed: `enabled: true`, allow-listed, load path present, `dist/index.js` present (11,826 bytes, built 11-09 22:53Z). The CLI reports `Status: loaded`. | `/root/.openclaw-main/openclaw.json`; `openclaw --profile main plugins inspect ops-intake` |

What this does and does not show:

- The router did not handle a single ask on 11-11. That is measured.
- Why is **not verified by me**. The config, the files and the CLI all say the plugin is
  fine. The unmerged commit on `fm/ops-intake-before-dispatch-j3` (open PR #1915 as of
  15:36Z on 11-13) says the `inbound_claim` hook is never called for a plugin without
  a conversation binding on
  2026.8.35. I confirmed only that the installed build registers `inbound_claim` and
  not `before_dispatch`; I did not trace the runtime's call sites.
- Whether the daemon loaded the plugin at all is also open. The CLI loads plugins in
  its own process, so its `loaded` says nothing about the daemon.
- The startup list may not be exhaustive: `openrouter` and
  `muso-credit-verification-enforcer` are allow-listed and absent from it too. I did not
  check whether those two are working.
- `docs/support/ops-intake-router.md:3` said "Status: live on main". As measured, the
  router was not intercepting; that doc's "What is (and is not) switched on" section now
  carries the caveat and points back to section 3 here.

**Correction.** The first version of this report (commit `a889452e5`, and my status
lines of 11-11) said the installed extension had no `dist/index.js`. That was wrong: I
listed the directory through `head -5`, which cut the listing off after `envelope.js.map`.
The file is there.

With the router not intercepting, the agent did things `AGENTS.md` says the Ops agent
turn never does. All of these are quoted from the bot's own thread messages:

- It **attempted credit approvals**: "Walking on the Shoreline" (#3, 16:31Z) and three
  requests on #5 (16:38Z). The backend gate refused all four; 0 statuses changed.
- It **sent hand-composed customer-facing replies** on #3 (16:31Z) and #4 (16:35Z), and
  says it did on 215476530103234 (16:21Z). These did not go out as answer-bank lines.
- It filed ClickUp cases `1amvh556pkz` and `1amvh556pma`, tried an artist contact form
  for #4 (not submitted), and escalated to Nick at 16:44Z.

The backend gate is the only thing that stopped four approvals that day.

## 4. Drafted close-out for Jan (not posted, by decision)

One block per conversation, written as a thread reply on the root ts in section 1.

**215476530103259** — Jan, the customer wants duplicate profile `00992bba` gone, verified
profile `11c9e78d` kept intact, and the wrong "Insomnia" listing `5faae9a9` folded into
the correct one `c400e00a`, with a confirmation when done. Verified (credit_requests
replica, 17:25Z): `11c9e78d` has one request, approved 2026-07-17; `00992bba` has none.
Unverified: merge complete and both tracks still present (bot notes only). The customer
has had no reply in this conversation since 10-23. Next: you remove the credits from your
own login with the `muso-ops-tracks` Removal Requests procedure, then reply to the
customer. Decision for you first: remove only this profile's 8 credits (the wrong listing
stays public) or remove the whole duplicate track (12 credits on 2 profiles, which is
what the customer asked for).

**215476692820441** — Jan, the customer wants a human to accept his Pro Tools session and
master screenshots plus his Fiverr relationship with the artist as proof for Mixing and
Mastering on "MDS" and "Locked In". Verified (credit_requests replica, 17:25Z): both
requests are in verification needed, untouched since 11-04 01:39Z; "MDS" is held as
`hold_for_documents / one_person_unanchored`. He asked for a human on 11-04 03:07Z and
has had no reply for 7 days. Next: you reply to him in Intercom today as a person and ask
for one thing, the Fiverr order showing the buyer and the two track titles, or a message
from the artist. Both requests stay in verification needed until that arrives.

**215476700995903** — Jan, the customer is fed up with proof requests on nearly every
release and asks whether the studio account needs anything more. Verified
(credit_requests replica, 17:25Z): 31 open across two profiles. Personal `2b730586`: 9
verification needed, 1 unverified, 410 approved. Studio `fd06caaa`: 10 verification
needed, 11 unverified, 372 approved. He was told at 16:31Z today not to resend anything.
The bot's attempt to approve one was refused; nothing changed. Next: you or Nick work
ClickUp `1amvh556pkz` track by track from your own login, then reply to him with the
outcome.

**215476584423897** — Jan, the customer wants a decision on 13 mastering credits for one
album after sending two documents on 10-27. Verified (credit_requests replica, 17:25Z):
all 13 are in verification needed and have not been touched since 10-27 21:57Z. He got a
status reply at 16:35Z today. No inquiry reached the artist. Next: Nick answers the bot's
16:44Z escalation. Decision for Nick: accept the recording engineer's Sep 24 email
(on file, per the bot's note) as third-party confirmation, or hold all 13 until the
artist confirms.

**215476639942446** — Jan, the customer wants a decision on 8 mastering credits on one
album and sent an artist Instagram post and two articles naming him. Verified
(credit_requests replica, 17:25Z): 5 of the 8 were approved 11-10 12:38Z by
`agent-precedent@muso.ai`. 3 are still in verification needed, untouched since 11-03:
Arbol `09b25a9c`, Prima di Colombo `7be154dd`, Pensare come i pesci `bfc9f279`. Same
album, same role, same hold reason as an approved sibling. He has had no reply since
11-04. Next: you decide those three from your own login (case `1amvh556pma`), then reply
to him.

## 5. Method

- Intercom REST v2.11, `GET /conversations/{id}?display_as=plaintext`, existing token,
  script streamed over stdin to node-8. All five read in full, notes included.
- Slack `conversations.history` and `conversations.replies` with
  `MUSO_SLACK_BOT_TOKEN_OPERATIONS`. No `chat.postMessage` call was made.
- Trino via `/opt/hydra/scripts/trino-query.sh`: `credit_requests`, `users`, `claiming`.
- `scripts/ops_intake/summarize.py` was not run: `facts.quote_customer_text` writes an
  injection-watch record on the host, and this task was read-only.
- node-8 was on hydra `87027e7404d56b5e97f7029933fc54c908a08228`.
