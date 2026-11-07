# Request status updates — nobody waits on us in silence

Every request a user files with us (a credit request, a profile claim, a merge, a data erasure, a
refund) gets an automatic message on its own channel **at each state change** and **at least every
48 h while it is open**. One ledger records what each user was told and when; one hourly driver
sends; one copy file decides the words; nothing sends until the words are approved.

```
scripts/request_comms/       the implementation (store, sources, guard, identity, routing, channels, lines, report, driver)
scripts/request-comms.py     the CLI: tick | report | check | stop
policies/request-status-lines.json   the ONE copy file (ships off)
scripts/check-request-status-lines.py   the CI guard over that file
tests/test_request_comms.py  the failure modes, each one a customer-visible incident if it regresses
```

## The three switches (a deploy can never flip copy on)

| switch | where | effect |
|---|---|---|
| kill | `/etc/hydra/request-comms.disabled` | the tick returns 0 and does nothing |
| driver | `policies/request-status-lines.json` → `"enabled"` | false = every tick is a dry run |
| live host | `/etc/hydra/request-comms.live` | absent = dry run (also the CLI default) |

**A line sends only when it is `enabled: true` AND carries a real `approval_ref`** — a placeholder
(`""`, `unapproved`, `pending`, `tbd`, …) is not an approval, and an enabled line whose review still
says `pending…` is a policy error (exit 2), the digest line included. Everything else is held and
shows up in the ledger as `line_locked`. Today exactly one line is enabled: the erasure
acknowledgement v2 (`approval_ref: gdpr-ack-v2-1101`, ruled 2026-11-01). Every other line is
`"review": "pending-fable-r5"`.

That ack is **erasure copy** — it opens "we have your request to remove your personal data from
Muso" — so it may only reach the register classes whose request that sentence is true of:
`sources.ERASURE_ACK_CLASSES = ("privacy_erasure",)`. A `privacy_access` row is an
Art. 15 request for a *copy* (the pipeline answers it captain/counsel, no hide) and a
`dmca_takedown` row is a rights-holder's copyright notice; telling either of them they asked us to
delete their data is a false statement to the person who wrote in. Those rows map to `unknown`,
which the planner **holds** — never messaged, never guessed at. A register with no `class` column
is held the same way: without the class we cannot prove the words are true.

`legal_threat` is the subtle one, and it is why the tuple is `copy.ASK_APPROVED_CLASSES` and **not**
`run.ERASURE_FAMILY`. A legal threat is in the erasure *family* — it gets the erasure pipeline's
handling — but it is not a request to remove personal data, so the ack's words are not true of it
either. The two tuples answer the same question ("may erasure copy be sent to this class?"), so a
test pins them equal; widening this one to the family is exactly how a legal threat would be told
it asked us to delete its data. Adding a class releases customer-facing copy, so it is added in the
PR that carries that class's ruling. The shipped driver `enabled` is `false`, so the hourly timer
installed by `scripts/install-aux-units.sh` runs in dry run and sends nothing.

The unit calls `request-comms.py tick --live --json`, and that flag is **not** one of the switches:
`live = (not --dry-run) and the live file exists and the policy is enabled`. Without `--live` the
timer would be a device that *looks* live — the live file and the policy switch could both be on and
every tick would still be a dry run. The kill file and the absent live file are what keep it dark
today; `--live` only lets them take effect.

## What the user is told

One fixed sentence or two per `(request type, state)` from `policies/request-status-lines.json`.
States are `received | verifying | need_you | decided`, plus `waiting` — the line used when
nothing changed and the request is still with us.

The rules are mechanical, not stylistic (the CI guard fails on each):

- **never a reason, score, band, flag or rule name** — the reviewer's reasoning and the fraud
  lens's view never leave the store;
- **never a date promise** — no approved line may name a clock that no process enforces;
- **never a promise about the outcome** — the decline line says a request is closed when the
  information was not enough; the erasure acknowledgement says what happens next, not what will
  be deleted;
- **band-invariant** — there are no per-user variables at all, so the same state is the same bytes
  for every user. The single variable is `{date}` (the request's own arrival date) inside the
  approved erasure acknowledgement;
- **carried, never retyped** — the decline line is `answer-bank.ts#declined` and the erasure
  acknowledgement is the approved v2 block in
  `workspaces/support/reference/gdpr-erasure-requests.md`; the guard compares both byte for byte
  against their own source, because two copies of one approved sentence is how a company says two
  different things.

## Channels: bell → Intercom → email

1. **In-app bell, attempted first** — it needs no identity and no copy of ours, so it is the one
   rung that can go out **while our own lines are still pending review**. The ten status bells are
   live in both Novu environments (`NOTIFY_STATUS_BELLS=on`, `NOTIFY_MODE=novu` at 100 %; verified
   2026-11-03) and **had never rung for a real user** — three triggers in all prod history, all
   drills, because no caller existed. This driver is that caller for the states it owns.

   The contract (`services/notify-gateway/src/server.ts` + `workflows/catalog.ts` in
   muso-messaging, the lane that built them): `POST /v1/workflows/<kind>/trigger`,
   `Authorization: Bearer $NOTIFY_SERVICE_TOKEN` (a single `onRequest` hook guards every route but
   `/healthz`, `/readyz`, `/metrics`), `Idempotency-Key`, and a Knock-shaped body
   `{"recipients": ["<user id>"], "data": {"profile": {"name": ...}, "count": N, ...}}`. It answers
   `{workflow_run_id, visibility?}`. `workflow_run_id` is required; when `visibility` is present it
   must name **this** user with **at least one delivery leg true**, or the item reached nobody →
   `unconfirmed` and the driver climbs. `visibility.<uid>` carries one flag per surface the gateway
   knows about — `feed` (the in-app bell), `knock` (the Knock leg) and `push` (a device push) — and
   the gateway's contract is that **all-false** means nobody saw it, so any true is a delivery.
   Counting only `feed` read a real push as "reached nobody" and climbed to Intercom, sending the
   same update twice; today most users are exactly that shape, because the web reads Knock and the
   app builds that read our bell are not released. Two things verified against the live cluster on 2026-11-03 with a read-only probe:
   the `kubectl` selector finds both running pods, and **an unknown workflow kind answers `200` + a
   `workflow_run_id` with no `visibility`** — so the kind is checked against the pinned ten in
   `channels.bell` before the call (`rejected`, never a "maybe" that would block the pair forever). `data.profile.name` is interpolated into all ten kinds, so it is always sent:
   hydra has no profile-name reader on the core replica (there is no name column in postgres), and
   the band-invariant true value is `"your profile"`. **`data.request_ids` is always sent** — it is
   the gateway's per-request dedupe key (muso-messaging #82, `dedupeAgainst`), and when a caller
   omits it the dedupe falls back to *profile* scope, which would suppress a legitimate bell or let
   ours double the product event's own more-info-needed bell for the whole profile instead of the
   one request. The same field is what makes hydra's `*_needs_proof` bells collide correctly with
   the proof-ask sender (`scripts/notify-bell.sh`, hydra #1396) instead of ringing twice.

   Kinds and their states (`scripts/request_comms/routing.py`, pinned to the ten that exist; a
   policy may restrict the map, never invent a key):

   | state | credit | claim | merge |
   |---|---|---|---|
   | received / verifying (and the 48 h `waiting` line) | `credit_status_in_review` | `claim_status_in_review` | `profile_merge_queued` |
   | need_you | `credit_status_needs_proof` | `claim_documents_needed` | — |
   | decided | `credit_status_approved` / `credit_status_declined` (by raw status) **held** | `claim_approved` **held** | `profile_merge_done` **held** |

   `credit_status_doc_received` maps from a raw `doc_received` status when one appears. The
   **held** rows are the sender-map rule, not an oversight: core's S1/S2 notice owns a decision, so
   hydra does not double it. If the captain decides hydra should own decision bells too, that is
   one sender-map change — the kinds are already mapped.
2. **A locked line goes out as a bell only.** Every line but the erasure ack is `pending-fable-r5`,
   and a bell carries none of our text: the words are the catalog's. So `line_locked` no longer
   means silence for a state that has a kind — it means bell-only, never our unapproved sentence on
   another channel.
3. **Intercom**, only when the contact resolves to **this account** by the r5 rules
   (`scripts/credit_review/identity_resolver.py`: the professional id, the Auth0 subject, or a
   processed profile the account holds — exactly one owner, no reverted claim elsewhere). Never a
   name match, never a fuzzy email search, never "the only lead with that address".
   A **threaded** type (`routing.THREADED_TYPES`, today just `erasure`) replies on the requester's
   own conversation (`POST /conversations/<id>/reply`, a `comment` from an admin) instead of opening
   a new outbound message. The approved acknowledgement promises "Written confirmation on this
   thread" and the reference doc says "first reply, same conversation, always", so a new thread
   would leave the one they wrote on unanswered while a second appeared beside it. With no
   `conversation_id` on the row the request is **held** (`no_thread`), never sent as a new message
   that breaks its own promise.
4. **Email** through the send-gateway, only when there is **no** Intercom identity, and only for a
   request type with a configured template key. A type with no key gets no email rung and says so;
   it is never silently re-routed. "No Intercom identity" means a lookup that **completed** and
   found no contact. A lookup that **failed** (a search that timed out, a resolver that raised) is
   `identity_unknown`, not "no contact": the user may well have a contact with a channel-specific
   preference or opt-out, and a timeout must not route around it. The request is **held**
   (`identity_unknown`) and retried next tick, and a bell rung that needs no identity still goes.
5. **Email carries the approved line, not just a key.** The gateway renders the *template*, so the
   payload ships `data.event.status_line` (plus `state`, `request_type`, `request_ref`) and every
   template key must be registered with a body of `{{event.status_line}}`;
   `channels.email.template_uses_line_text` is the policy's promise that they are, and enabling the
   rung without it is a policy error. Otherwise a template could substitute its own copy while the
   ledger hashed the sentence we approved.

The rules survive the fallback. The ladder picks the first rung, and a rejected rung may climb to
the next one, but **never onto one this request is not eligible for**: a person with a resolved
Intercom identity is not emailed when Intercom refuses the send (that refusal can be a
channel-specific opt-out), and a rung an operator switched off is not available at all. And the
confirmed-email read happens whenever **either** the email rung or Intercom is on: resolving an
Intercom contact starts from that address, so gating the read on the email rung alone left
Intercom-only configurations holding every line as `no_route`.

A failed identity lookup is a reason to **wait**, not a reason to say there is no route: the hold
reason is `identity_unknown` (distinct from `no_route`, which means the ladder really is empty),
so the row stays visible with the real cause recorded and the next tick can resolve it.

The rule holds on the **fallback** too, not just at planning time. A request with a bell kind is
planned without resolving identity (the bell needs none), so the ladder can reach the email rung
later — a bell that reached nobody, an Intercom refusal — and resolve identity *there*. `_deliver`
applies the same test: a contact means this is not the email rung's user, and an **unknown** lookup
means we cannot tell, so the rung is held and the attempt is recorded with its reason. Only a
lookup that completed and found no contact falls through to email.

A confirmation counts as sent only when the provider's own answer says so: Intercom's message
`id`, the send-gateway's `status: sent`, the bell's `visibility` naming this user with any leg true.
An **uncertain** answer (a timeout, an unreadable body, a **5xx**) is treated like sent for dedupe —
the same pair is never re-offered — because a duplicate status line costs more than a missing one.
Only a clean `rejected` (the transport says nothing landed) may be retried on the next tick.

`rejected` is narrower than "any error", and the rule is the same on **all three** channels: a
**4xx** is a definite non-delivery (the provider refused the call before it created anything — 401
on the token, 400 on the body, 422 on the payload, 429 on the rate limit), and a **5xx is
`uncertain`, never `rejected`**. Any of the three can create the message and still fail the answer,
and calling that a non-delivery would let the driver climb to the next rung or the next tick retry
and send the same update twice — the email retry even carries a new idempotency epoch, so the
gateway cannot dedupe it either. The bell additionally treats the node script's own
`status: rejected` (no service token, printed *before* its POST) as a definite non-delivery, and
the send-gateway's own `status: suppressed`/`unsubscribed` on a 2xx as a definite refusal: those
are the provider saying it did nothing, not an ambiguous transport failure.

## Who is never messaged

Read from the three places that already own the answer, by one reader
(`scripts/request_comms/guard.py`):

- `policies/fraud-lens-holds.json` (messaging-only holds; an entry stops applying after its
  `review_by` day),
- `policies/credit-trust-decide.json` → `deny_user_ids`,
- the fraud lens's account-hold ledger through `credit_review.comm_state.held_user_ids` (the only
  reader of that file — never parse it directly).

The deadline patterns are deliberately wide, because a date promise is the one thing the policy
forbids outright (no process enforces it) and the gate must not be evadable by writing the number
out. `within 2 days` was banned while `within two days`, `in three weeks`, `by next Friday` and
`next month` all validated clean, so an editor could enable a non-verbatim line with an approval
ref and ship a promise the policy forbids. A count is therefore matched as **any short run of words
before a time unit**, not as a list of the numbers we thought of: enumerating `one` … `twelve` left
`within thirteen days` and `in twenty days` validating clean, which is the same evasion one number
further out. Digits are matched too, and relative weekdays and `next`/`this`/`end of` week, month
and year are covered. The run is bounded so the pattern cannot walk across a sentence, and the unit
word is what makes it a deadline rather than ordinary prose — `Your request is in review.` and
`We are still working on your request.` still validate.

A `verbatim: true` line waives the banned-wording regex because it is supposed to BE an already
approved block, so the waiver is earned, not claimed: the text must byte-match one of the pinned
sources (`answer-bank.ts` `declined`, the `gdpr-ack-v2-1101` block). A made-up `source` is a policy
error, and if the pinned sources cannot be read nothing is verbatim. `enabled` uses the same
approval test as sending: a placeholder `approval_ref` (`pending`, `unapproved`, ...) is a policy
error, so copy CI cannot be green while a live tick would hold the line.

**An approved block is bound to the line it was approved for.** `lines.PINNED_BINDINGS` ties each
`approval_ref` to one `(type, state)`, one pinned source name and the file its bytes come from, and
both the validator and the CI checker enforce it: a ref is not a movable label. Swapping the credit
decline and the erasure ack (texts and refs) used to validate clean, and would have sent a
data-erasure requester a credit-decline letter.

The cap groups by the identity it counts: `Plan` grouping, `sent_today` and the report's
`max_per_user_per_day` all use `cap_key`, so `A@Example.com` and `a@example.com` are one person.

**One digest is one message event, even when the provider gives us no id.** A timeout answers
`uncertain` with no message id, and the driver writes one row per digest member, so the report's
cap proof fell back to the row id and read a two-request digest as two messages — a false cap
breach and exit 3 for a single attempted event. Every member row now carries the `event_id` the
driver used as its idempotency key (`request-status:<type>:<id>:<state>:<cycle>`), and the proof
prefers the provider's id, then that, then the row.

**A missing ledger is not an empty one.** `Store()` creates the file and its parent, so pointing
`request-comms report` at a deleted or mistyped path used to return zero rows, `chain_intact: true`,
no problems and exit 0 — a clean bill of health for evidence that is gone. The report now refuses:
`missing_ledger: true`, `chain_intact: false`, a problem naming the path, and exit 3. It never
creates the ledger it is measuring.

An erasure ack's **slots** are approved copy too: `slot_required` lines may only use slot text that
byte-matches an entry in the GDPR source's "Fixed slots (pick, never edit)" block, and slot text is
subject to the same banned-wording, internal-surface and placeholder checks. Validating only
"non-empty" let an unapproved sentence ride along with the approved ack.

**Claim decisions are core's to announce**, like credit decisions: core's S1 route sends
`profile_claim_accepted` / `profile_claim_rejected`, so `(claim, decided)` is in the sender-map hold
set and this driver cannot double it.

The digest line is never `verbatim`: it is composed here (count, titles) rather than carried from an
approved source, so the flag could only ever skip the wording gate.

**A state you re-enter is a new update.** The dedupe blocks the *transition*, not the state name
forever: `verifying -> need_you -> verifying` is three changes and three messages. Only a claim for
the current state that is newer than the last thing we told them still blocks — the crash-mid-send
case, where a `sending` row exists and nothing settled.

**The fraud lens does not govern legal or commercial obligations.** `policies/credit-trust-decide.json`
and the fraud-lens holds exist to stop us telling a lensed person about their credits; they are not a
licence to drop a data-removal acknowledgement. The erasure and refund lanes are exempt from the ban
check by design (`driver.LENS_EXEMPT_TYPES`) and are audited like any other send; credit, claim and
merge stay lensable.

**A 2xx we cannot read is a maybe, never a no.** Both pod adapters keep only the status code when
the provider's body is empty or malformed, so `{http: 200}` used to classify as `rejected` and the
driver could send a second copy (next rung, or next tick). A 2xx with no parseable confirmation is
now `uncertain` on both the bell and the email rung; a definite `rejected` still needs either the
node script's pre-POST refusal or an answer that refuses (4xx/5xx, or an explicit decline status).

`tick --live --dry-run` is refused: two switches that disagree, where the dangerous one used to win.

Fail-closed: a missing or unreadable **policy** file refuses the run outright; so does a ban file
that lost its keys (`entries` / `deny_user_ids`), carries the wrong shape for them, or lists a value
that is not an account id — an absent key is not "nobody banned", and a bare string of ids is not a
list (iterated per character it bans five accounts nobody has ever heard of while the account the
line was written for goes unheld); and a lens ledger
that cannot be read (missing, older than 72 h, future-dated) puts **every** user in the banned set
for that tick. Neither case is ever reported as a clean run.

## The 48 h floor is a send; 24 h is the target we measure against

While `waiting_on` is us and nothing has changed, the driver sends the `waiting` line once the
clock passes `last_told_at + 48 h`. Every open request of ours with nothing sent for more than
**24 h** is counted as a **breach** in the report — the captain's rule for our own side is 24 h, so
48 h is the honest fallback, not the goal. **When the request is waiting on the user, the floor does
not repeat**: they owe us something, our silence is not the failure the floor exists for, and a
`needs_proof` bell every two days is a nag rather than an update. The state *change* to
waiting-on-the-user still goes out — that is the first notice, and it is the one that matters.

## Dedupe and caps

- per **(request, state)**: claimed in the ledger *before* the network call, so a crash, a
  timeout or a rerun cannot double-send;
- **a maybe is never a no.** `uncertain` (a lost reply, a `kubectl exec` that died after its POST, a
  timeout) means the call may have landed, so it stops the ladder and is never repeated. Only a
  definite non-delivery (a pre-POST refusal, an HTTP answer, a clean `rejected`) climbs to the next
  rung and is re-offered next tick — the other reading sends a person two copies of one update;
- **but a claim silences one cycle, not the request.** An attempt whose reply never came back
  (`sending` / `uncertain`) blocks the same state for `FLOOR_HOURS` from the attempt, and no
  longer. Once the floor has run out again since that attempt, the user may have heard nothing for
  96 h, so the driver tries again rather than let one lost reply mute the request permanently. An
  unreadable claim stamp cannot establish a live cycle either, and the promise to the user outranks
  a possible duplicate;
- the fallback climbs only rungs that are **switched on** in the policy: a bell that reached nobody
  does not fall through to Intercom on a host where Intercom is deliberately off;
- per **user per UTC day**: one message at most, across every request type — several due requests
  for the same person collapse into ONE digest line, and every member of that digest is marked
  told. The day's counter counts **`sent` and `uncertain`**: when a provider times out after
  delivering, we cannot prove the message did *not* arrive, and a second message to somebody who
  already got the first is the failure the cap exists for;
- per **message event**, not per attempt: the idempotency key is
  `request-status:<type>:<id>:<state>:<cycle>`, where the cycle is the last time we **attempted**
  anything on that request — a confirmed send, or a `sending`/`uncertain`/`rejected` row. Keying on
  `(request, state)` alone made a 48 h reminder the *same event* as the first letter — notify-gateway
  answered its idempotent skip and the ledger recorded a delivery nobody received. Keying on the
  last *confirmed* send was the same bug one cycle later: a reminder whose reply was lost still
  spent a key, so the re-armed cycle at T0+96 h regenerated it and the gateway deduped a message the
  user never got. The key is stable across a retry inside one tick (the epoch is a snapshot) and
  distinct per cycle; the email rung uses the same key (it used to key on the bare request ref);
- per **run**: `--max-per-run` (default 50, i.e. ~1,200 messages a day at the hourly cadence) is a
  per-tick **budget**, not a refusal. The backlog is real and measured: **7,869 users** had an open
  credit or claim request move in the last 30 days, and **99,902 breaches of the 48 h floor** were
  counted on the first full dry run. Refusing the whole tick would mean no backlog ever clears,
  while sending the oldest N one message each does clear it — so the remainder is deferred to the
  next tick and **counted** on the tick line, never dropped silently. Oldest-due first;
  one message per user per day; a person with several due requests gets ONE line.

## Scope: which requests this feed is responsible for

`policies/request-status-lines.json` → `sources.window`. An **open** request is in scope while its
owning row moved within `open_active_days` (30), a **decided** one for `decided_days` (14). The
universe is far larger — 100,938 credit requests are open today, 62,268 of them untouched for
91–365 days — and telling someone their year-old abandoned request is "still with our team" is a
product decision, not a driver default. It is scoped by **update** time and nothing else: an open
request created a year ago but touched today is exactly the one whose state just changed, so a
creation-age bound would drop it before the window could see it (and `stale_open_rows`, which counts
by update time, could not report it either). Rows outside the window are **counted, never hidden**
(`stale_open` on every tick line and in the tick snapshot: 66,642 credit + 471 claims at the time
of writing). Widening it is those two numbers.

## Failures are loud, never empty

| condition | behaviour | exit |
|---|---|---|
| copy policy invalid | refuses before reading anything | 2 |
| ban list unreadable | refuses, sends nothing | 2 |
| fraud lens unreadable | holds every credit/claim/merge send, names the reason | 3 |
| a source unreadable, or a store we expect is missing | that type gets nothing this tick, the summary names the reader | 3 |
| a lane with no reader yet (`merge`, `refund`) | that type gets nothing this tick, the summary lists it as off by design | 0 |
| more than `max_per_run` due | sends the oldest `max_per_run`, counts the rest as deferred | 0 |
| an enabled line (the digest included) still carries a placeholder approval | refuses before reading anything | 2 |
| audit row neither recorded nor spooled | flags it on the tick | 5 |

A source's own store can be unreadable in ways that are not `RuntimeError` — a corrupt or non-SQLite
file raises `sqlite3.DatabaseError`. That is classified at the source boundary as `unreadable`
(the other types still send, the tick exits 3 and names the reader), never allowed to end the tick.

An unreadable source is **UNKNOWN, not empty**: a silent empty read would tell a user "nothing is
happening" while we are blind to their request. The same rule applies to the ticket-backed types:
`merge` and `refund` get no messages until a ClickUp-ticket → Muso-account identity resolver
exists, because a ticket carries no user id and a name or an email string is not an identity.

**But a lane that was never switched on is not a failure.** `merge` and `refund` are `disabled` on
every tick by design, and `request-comms.service` has no `SuccessExitStatus=`, so treating them as
`unconfigured` (exit 3) left the hourly unit permanently failed — and made a real outage in an
enabled source indistinguishable from the expected gap. `disabled` stays visible in the summary
(`disabled_sources`, and a `lane off (by design, not a failure)` line in the tick render) and exits
0. `unconfigured` is reserved for a store we EXPECT and cannot find (the GDPR register), which is
a real outage and still exits 3. `InstalledTickTests` pins the installed unit's default
configuration and exit code, and asserts the premise (no ticket reader, no refund tags) so the
contract is revisited if one ever ships.

## The ledger

`/var/lib/hydra/request-comms/state.sqlite` (dir 0700, file 0600 — under `/var/lib` because the
deploy rsync owns `/opt/hydra`), one append-only table `request_comm_state`:

```
at · request_type · request_id · request_ref (type:id) · user_id · channel_pref · state
   · last_told_state · last_told_at · next_due_at (= last_told_at + 48 h while open)
   · waiting_on · outcome · line_key · detail(JSON) · prev_sha · sha256
```

Every row is one event (`observed`, `sending`, `sent`, `rejected`, `uncertain`, `held`,
`would_send`). Append-only is enforced by the database (BEFORE UPDATE/DELETE triggers `RAISE
ABORT`) and every row is sha256-chained to its predecessor, so a deleted or edited row is
detectable (`Store.verify()`, surfaced by the report as `chain_intact`).

`waiting_on` comes from the owning table; when the S0 sentinel evaluation store exists and is fresh
(≤ 6 h) its per-`request_ref` `waiting_on` refines it. The sentinel is an enrichment — the floor
never depends on it.

**Freshness is decided per ROW, not by the database file's mtime.** A recent write for one request
keeps the whole file's mtime fresh, so an mtime check alone let an old evaluation of `credit:old`
(`waiting_on=user`) overwrite the owning table's current answer (`waiting_on=us`) and suppress that
request's 48 h reminder — and drop it from breach reporting. A row is used only when its own
timestamp (`evaluated_at`, `at`, `updated_at`, `observed_at`, `created_at` or `ts`, ISO-8601 or
epoch) is within the window. A row with no readable timestamp, or a table with no timestamp column
at all, contributes nothing: we cannot prove it is current, so the owning table's answer — the one
we can date — stands.

## Keeping the promise honest at the edges

- **A bell override is bound to what the row can actually say.** `channels.bell.workflow_keys` may
  pick a kind for a `type/state` only from `routing.bell_allowed_keys(type, state)`: the kind the
  default mapping gives that state, plus the kinds of the raw statuses that MEAN that state. Three
  ways to be wrong, all refused: another type's kind (`credit/received -> claim_approved` tells a
  credit requester their claim was approved), this type's kind for a state the row is not in
  (`credit/received -> credit_status_approved` announces an approval that does not exist), and the
  48 h floor's fallback kind (`credit/need_you -> credit_status_in_review` tells somebody who owes
  us proof that their request is "in review"). That fallback exists so a *reminder* can reuse
  `verifying`'s words when a state has no kind of its own; it is chosen by the driver for reminders
  only, never by the policy. `bell_key()` also refuses such an override and falls back to the
  pinned map, so an old policy file cannot announce it either.
- **An override may narrow what the row says, never contradict it.** `credit/decided` can
  legitimately ring either `credit_status_approved` or `credit_status_declined`, so the static gate
  cannot tell them apart. When the owning row carries a `raw_status` that already names a kind, an
  override naming a *different* kind of the same state is ignored and the row's own kind wins —
  otherwise an approved credit could ring "declined".
- **One person, one daily cap.** Erasure rows arrive keyed by the requester's email (or a contact
  id) while credit and claim rows carry numeric account ids, so a raw comparison let the same person
  get an erasure ack *and* a credit status on one day. Email-shaped keys normalise to
  `email:<lowered>`, the erasure's email is resolved to its account id when the replica can (bounded
  to the handful of erasure rows), and `sent_today` normalises in SQL so older rows count too. When
  that lookup FAILS the erasure rows are held (`cap_identity_unknown`) and the tick exits 3: we
  cannot prove they are new people, and an ack plus a status on one day is what the cap exists to
  stop.
- **A request we already messaged does not fall out of scope.** The update window keeps year-old
  abandoned requests out of the feed, but it must not end the 48 h promise for someone mid
  conversation: refs our ledger has told are read back by id even when the window has closed on them
  (counted as `kept_in_scope` on the tick line). Scope-stale rows we have never messaged stay
  counted, not messaged.

## Safety rails on the tick itself

- **One tick at a time.** The ledger is append-only, so a `sending` claim is not a constraint: two
  ticks could both read an empty "who has already been told" map, both claim the same
  `(request, state)`, and both call the provider. The tick holds an exclusive lock on
  `<store>.lock` for its whole run; a second one reports `mode: busy` and sends nothing.
- **No unauditable send.** The tick asks whether it can record an audit row **before** the first
  send. If neither ACTION-AUDIT nor the spool can take it, nothing is sent (exit 5) and every plan
  waits for a tick that can. If the surface breaks mid-batch, the batch stops there instead of
  sending the rest blind. The preflight proves the **spool** writable in *both* branches, not only
  when the ledger import fails: an importable ledger can still refuse a row (locked, read-only,
  schema drift) and `record` then falls back to that file, so checking it only on `ImportError`
  made the preflight fail open on exactly the case it exists for — the first message went out,
  `record` answered `unavailable`, and exit 5 arrived after the send.

## Measuring it (this is the point)

```
sudo /opt/hydra/scripts/request-comms.py report --days 7
```

per request type: requests seen, messages sent, **time-to-first-message p50/p90**, **max gap
between messages p50/p90**, the longest silence right now, and the breach counters (`> 24 h`,
`> 48 h`). Plus the two honesty checks: `messages per user per day (max)` must be 1, and the
ledger chain must be intact — if either is off the report says so instead of averaging it away.
The cap counts **provider messages**, not ledger rows: one digest writes a row per request it
covers, and those rows share the provider's message id, so a two-request digest is one message.
It also counts **`uncertain`** rows, not just `sent`: the live counter (`Store.sent_today`) does,
because an uncertain provider answer may have delivered, and proving the cap from `sent` alone
read one uncertain credit update plus one sent claim update for the same person on one day as 1
with no problem reported, while two messages may have arrived.

Silence is measured from the **first time we saw** a request (`first_seen`), never from the newest
ledger row: a `held` row carries no `created_at`, and reading one there made an unsent, held request
look like a request with nothing to measure (`silent = None`, `breach = 0`) — the dry run would
claim the 48 h floor was met while the person heard nothing for days.

Silence is also **open requests only**. A `decided` request is terminal and no longer owed updates,
so its age is not silence: counting it let a claim closed and messaged 24 h ago report
`silent_now_hours_max: 24.0` with no open claims at all, and dominate the headline with a number
that implies an open request went quiet. `routing.breach` already excludes terminal rows; the
silence stat now uses the same rule.

The numbers are computed from the ledger's own rows, never from a journal grep, and they are
meaningful **before** the flip: dry-run ticks record `observed` and `would_send` rows, so the
report shows the size of the problem while nothing has been sent.

## Turning it on (in this order — every step is a separate decision)

1. `scripts/action_audit/` merged (the ACTION-AUDIT ledger). Until then every send is spooled to
   `/var/lib/hydra/request-comms/audit-pending.jsonl` and the tick says `pending`; the inverse of
   `message.send` is `request-comms.py stop --request-ref REF --state STATE`. A stop is a **standing
   instruction**, not a delay: it writes a `stopped` row that the planner reads before it decides
   anything, so the request is never messaged again (it used to write a synthetic `sent` row, which
   only bought 48 h and said something untrue in an append-only ledger). The stop is **per state**:
   `--state verifying` silences that line and nothing else, so the request's next state still gets
   its update. Omitting `--state` stops the whole request:
   `request-comms.py stop --request-ref credit:1`. `--state` is optional for exactly that reason —
   while it was `required=True` the documented whole-request command exited 2 before writing
   anything, so an operator believed a request was silenced while the next live tick could still
   message the user.
   `stop` takes the **tick's own lock**, blocking. A tick reads the stop markers once, before it
   plans, so a stop that landed mid-tick used to print "stopped for good" while that tick went on to
   send the very message it was told to suppress. Waiting for the in-flight tick makes the sentence
   true: either the tick has not started (it will see the stop) or it has finished.
2. The request-status bell workflow exists in notify-gateway (then `channels.bell.enabled` +
   `workflow_key`).
3. muso-messaging carries one `request_status_<type>` template per type (then
   `channels.email.enabled` + `template_keys`).
4. Fable r5 review of `policies/request-status-lines.json` → flip each line's `enabled` +
   `approval_ref`.
5. `"enabled": true` in the same file, then `touch /etc/hydra/request-comms.live` on node-8.
6. Watch the first tick: `command | journalctl -u request-comms -n 50`, then the report.

Never skip 4 to save a day: the whole reason this file is mechanically guarded is that a status
line which explains *why* leaks our internal judgement to the person being judged.

## See also

- `docs/support/caroline-safety-layer.md` — the answer bank and the output guard Caroline's own
  replies pass.
- `docs/credit-verification/verify-request-notes.md` — the one path that asks a user to verify
  credits (`intercom-verify-request.sh`); this driver never asks, it only reports status.
- `workspaces/support/reference/gdpr-erasure-requests.md` — the approved acknowledgement and the
  erasure rules this driver carries verbatim.
