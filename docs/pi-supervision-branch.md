# Pi supervision branch

![Multi-brain agent architecture: one agent, two branches of attention, events are commits](pi-supervision-branch-poster.svg)

This document covers the supervision branch that runs fleet supervision beside the captain's chat on a Pi primary.
Maintainers changing how wakes reach the branch, how its outcomes reach the captain, or how the attended and away postures differ need it.

The poster is the visual of the idea.
This document stays the owner and the contract.

## Find a topic

| What you want to know | Start here |
| --- | --- |
| What the branch handles and what stays on main | [Overview](#overview) |
| Which file owns each part of the design | [Components and their owners](#components-and-their-owners) |
| Why delivery never freezes the captain's terminal | [Off-thread delivery](#off-thread-delivery) |
| How a captain-facing event whose wake was lost still surfaces | [Lost-wake outcome backstop](#lost-wake-outcome-backstop) |
| What the branch sees of the captain's conversation | [How the branch knows what the captain said](#how-the-branch-knows-what-the-captain-said) |
| How outcomes are classified, shown, and acknowledged | [Two-stage noise filter](#two-stage-noise-filter) |
| How fleet-wide heartbeat reviews are routed | [Heartbeat routing](#heartbeat-routing) |
| Prompt caching and the branch model | [Cost model and the byte-stable prefix](#cost-model-and-the-byte-stable-prefix) |
| What changes while the captain is away | [Postures](#postures) |
| Which tests pin this contract | [Verification](#verification) |

## Overview

Fleet supervision on the Pi primary harness runs on a second conversation - the supervision branch - inside the same `pi` process as the captain's chat.

### What the branch handles while attended

Supervision is default-on.
Once a Pi primary session owns this home's fleet lock, the branch handles two kinds of work:

- Eligible task-local rows from ordinary actionable wakes.
  A row is one queued wake entry.
- Heartbeat scans that the cheap bash-level scan flags as possibly captain-relevant.

The branch then merges each outcome back into the captain conversation's transcript.

Some wakes stay on main:

- Ordinary main-only rows remain on main even when eligible task-local rows share their queue.
- A decision-owned signal or stale trigger keeps its entire coalesced trigger batch on main.
- An unresolvable row makes the scan unsafe and returns the whole wake to main.
- Every watcher-failure alarm also stays on main.

All of that describes the attended posture.
The away posture, recorded by `state/.afk-contract`, hands every row to the branch and parks main (see "Postures" below).

### How outcomes reach main

While attended, captain-relevant branch outcomes persist as exact, sequence-keyed visible transcript entries.
They then open one sequence-keyed processing turn on main, which stays open until main acknowledges that sequence.
While away, the entries persist but processing waits until the record is archived.

### Design source

The design source is the captain-approved forked-supervision architecture board.
That board is a captain-private fleet record: a self-contained HTML explainer with the measured cache and judgment evidence.
This document records the shape it landed as, and the delivering PR cites the board artifact itself.

### Pi-only scope

This in-process supervision branch is Pi-only by construction:

- The branch lives in `.pi/extensions/fm-branch-supervision.ts`, which only a Pi primary ever loads.
  No other harness gains branch supervision behavior.
- In a home with no branch state, the bash-side additions remain inert (`tests/fm-branch-supervision.test.sh`).
  `bin/fm-lease-lib.sh` owns how a pre-existing lease is honored on any harness.
  A home on any harness that already has an outcome store still receives the shared drain compatibility recovery described in [Lost-wake outcome backstop](#lost-wake-outcome-backstop).
- It does not change which harness is primary and never moves a home to Pi.

On a non-Pi home that runs the supervision host, the host runs the branch beside the primary, away and on Claude and Cursor also attended.
[supervision-host.md](supervision-host.md) owns its scope and mechanism.

## Components and their owners

- Wake dispatch: `.pi/extensions/fm-primary-pi-watch.ts` stays the dispatcher; `.pi/extensions/lib/fm-branch-dispatch.ts` owns the offer handshake and row eligibility, while [`watcher-continuity.md`](watcher-continuity.md#per-actor-acknowledgement) owns the per-actor consume contract.
  A successful row grant transfers ownership of exactly the currently branch-eligible rows to the branch; a check-kind triggering close (merge-confirmation polls, Relay mentions, credential/auth failures, and every other legitimately main-only class) is never offered even when other rows are eligible, no acceptor (extension absent, away mode, branch broken) keeps today's wake-to-main path for that close, and watcher-failure alarms always go to main because only main can repair the watcher cycle.
  A decision-owned event surfaced by `bin/fm-watch.sh`'s signal path gets the identical treatment even though it keeps the ordinary `signal` kind.
  `signal_files_actionable` marks the queued payload `needs-decision:` for a newly surfaced `needs-decision`, a `captain-held` declaration surfaced through the no-verb fallback, or a pending-reply second-mate escalation; `scopeForUnreadWake` excludes every marked row from what the branch may claim.
  A changed-file batch with non-decision files is coalesced into one ordinary row keyed by a stable batch identity (`signal-batch-<digest>`) whose payload is the compact, prompt-sized summary `signal: <N> file(s) (<S> status, <T> turn-end): <status path>... [+N more]` (up to five status paths, never a turn-ended one, capped at about 400 bytes); a decision-only batch writes no ordinary row.
  Each decision-owned file gets its own `needs-decision: <paths>` row carrying the batch's full path list and keyed by that file's status name.
  The path list of every queued ordinary batch lives in the private record `state/.signal-batch-paths`, written atomically by `bin/fm-watch.sh` before the row is queued and keyed by the same batch identity; a record is pruned on the next write once its batch key leaves the wake queue.
  The record holds only the files that are not decision-owned, so a decision task can never be claimed through the ordinary row even when a later heartbeat, not this batch's own trigger, offers it.
  `scopeForUnreadWake` resolves a batch row's tasks from that record, falling back to a legacy row's path-shaped payload tokens when no record exists; a compact-summary row whose record is missing makes the scan unsafe so it surfaces to main rather than being classified from the summary alone, while the decision row's status-shaped key keeps the trigger cross-reference below working.
  For a stale row, `scopeForUnreadWake` folds the mapped task's status log and excludes the row when any `needs-decision` remains open or the current meaningful declaration is `captain-held`; an unreadable or symlinked status log fails the scope closed rather than influencing routing.
  A stale row resolves to its task through the endpoint the task record names - the recorded `window=`, or the `terminal=` handle for an Orca task, since that is the target the watcher polls and keys the row by - and only a row no record names makes the scan unsafe.
  The dispatcher resolves trigger keys and every currently unread excluded decision row to task identity before cross-referencing them: any signal or stale trigger containing a decision-owned task goes wholly to main, including a batch that also contains routine rows, and an unread decision for one task keeps every later signal or stale trigger for that same task on main until the decision row is read, regardless of whether the rows use its status-file key or window alias.
  Other tasks remain independently eligible.
  The wake message's `signal:` payload is the compact batch summary above, and other harness-arm scripts remain unchanged because they match only the `signal:` prefix.
  A branch settlement owns only that wake's delivery: [`watcher-continuity.md`](watcher-continuity.md#actionable-wake-ordering) owns the rule that arming never waits on it, so a long branch turn never leaves supervision dark.
  Heartbeat handling remains independent.
  A fleet-wide heartbeat keeps its own all-or-nothing rule (see "Heartbeat routing" below): it takes every branch-ownable unread row or none of them.
  A co-present main-owned check row no longer defers that review to main, because it is not fleet context the branch is missing and main is woken for it on its own triggering close.
- The branch itself: `.pi/extensions/fm-branch-supervision.ts` creates the branch session, serializes wakes, mirrors dialog, and merges outcomes.
  The branch conversation lasts for exactly one main session: every main session start - a cold start, `/new`, `/resume`, `/fork`, or a reload - opens a NEW branch conversation, and a conversation recorded by an earlier session is never reopened as the live one.
  That keeps the branch reasoning from the current generated prompt and the current main dialog rather than from weeks of accumulated thread, where a superseded rule could still outweigh today's.
  Only a rebuild inside one main session, which is what a model or effort change triggers, continues that session's own conversation, and `state/.branch-session` records it.
  Earlier conversations stay on disk under `state/branch-session/`, exactly as Pi keeps its own session files, and are never reopened as live branch context; the effort picker may only inspect the model named by the current pointer as the last-resort lookup documented in [configuration.md](configuration.md#pi-supervision-branch-model-and-effort-configsupervision-branch-model-configsupervision-branch-effort).
  Nothing captain-facing rides on that conversation: the durable outcome store and its processed marker are what carry unacknowledged outcomes across the boundary, and they re-present on the new main session exactly as they do after a crash.
  It checks the current extension generation and `state/.lock` ownership before each guarded branch side effect so replacement or lock loss cannot let an old continuation mutate the new session.
  Those checks and the store calls around them are awaited rather than synchronous, and an explicit queue inside the extension is what keeps them serialized (see "Off-thread delivery" below).
  Every accepted path that cannot reach a working branch rejects its settlement to the watcher, which retains delivery ownership and routes the wake to main as a follow-up that counts as delivered once Pi accepts it; a broken branch declines later offers so they take that path directly.
  After wake rows are claimed, a branch prompt counts as handled only when `fm_branch_report` appends a durable outcome before that prompt settles; a settled provider error or a settled prompt with no report releases the grant and rejects delivery ownership back to the watcher.
  While a signal or stale prompt is open, `fm_branch_report` accepts only the tasks that prompt's claimed rows resolve to (a signal row by its status-log key, a stale row through the task record naming that endpoint); a report for any other task id, `fleet` included, is refused before the store is touched, so a task remembered from an earlier wake cannot become a delivered outcome, while a heartbeat review is not scoped by task.
  The branch's guarded commands never tell it to drain queued rows mid-handling: for that actor `bin/fm-guard.sh` keeps the queued-wakes warning silent, and an acknowledgement that consumed nothing reports that plainly with the exact command for the current wake (`docs/watcher-continuity.md` "Per-actor acknowledgement").
  Two consecutive settled provider errors latch the branch broken and surface a one-line health note only on that initial trip.
  Main keeps every wake during a five-minute cooldown, after which one wake may probe the branch while concurrent wakes still stay on main; each probe that settles with another provider error doubles the next cooldown up to one hour.
  A prompt from the current branch generation and model or effort selection that appends a durable `fm_branch_report` and then settles without a provider error clears both the latch and provider-error streak and surfaces a one-line recovery note; a provider error settled after that report wins instead, re-latches the branch, and extends the cooldown.
  A session replacement or branch model or effort change resets the recovery state immediately.
- Branch model and effort selection: the same extension registers `/supervision-model`, which picks the branch's model and then its reasoning effort, and applies both at the branch-session creation boundary; [configuration.md](configuration.md#pi-supervision-branch-model-and-effort-configsupervision-branch-model-configsupervision-branch-effort) owns the operator-facing schema and behavior.
- Branch system prompt: `bin/fm-branch-prompt.sh`; its header owns the byte-stable-prefix contract (no timestamps, no fleet snapshot, no per-wake content).
- Outcome store: `bin/fm-branch-outcome.sh`; its header owns the append-only format, read cursor, and bounded per-task status-coverage indexes.
  Outcomes are written to the store before delivery to Pi.
  A captain row advances the cursor only after its matching visible session entry exists, while locked session-start replay stops before the first captain row so it cannot acknowledge that outcome through prose alone.
  A routine note has no such sequence-keyed record, so if its cursor write fails after the note was delivered the next reconciliation sends that note once more.
  That asymmetry is a known limitation of the routine delivery representation rather than of the ordering above, it predates delivery moving off Pi's render thread, and closing it means giving routine delivery a durable idempotent record - tracked as follow-up `fm-pi-routine-delivery-idempotency-followup-r1` and pinned meanwhile by `tests/fm-pi-branch-extension.test.sh`.
- Consistency: `bin/fm-lease-lib.sh` owns the per-task lease contract, the main-only role partition, and the deliberate CONFUSED-AGENT-GRADE threat model these guards target (captain-decided; adversarial-grade separation is out of scope and tracked as follow-up design work); `bin/fm-lease.sh` is the command surface.
  The guards are wired into `fm-send.sh`, `fm-control.sh`, and `fm-teardown.sh` (overlap, lease-checked, with claim serialization retained through the mutation) and `fm-pr-merge.sh`, `fm-merge-local.sh`, and `fm-spawn.sh` (main-owned, branch refused; a relaunch through `fm-control` stays branch-legal recovery).
- Autonomy: supervision is default-on for every task once a Pi primary session owns the fleet lock (docs/configuration.md "Pi supervision branch"); no captain grant file is required.
  A fleet-wide heartbeat is separately eligible only when every row other than a check or decision-owned signal/stale row is a heartbeat row or a resolvable task-local row (see "Heartbeat routing" below); every other fleet-wide or unresolvable wake, and every watcher-failure alarm, stays on main.
  The branch recomputes eligibility immediately before prompting the branch to drain and publishes the exact eligible row set to `state/.branch-eligible-rows` through `writeEligibleRowsSnapshot`.
  After an independently eligible wake has already been offered, a newly-arrived main-owned row observed at that pre-drain recheck does not revoke the offer: it is excluded from the eligible set, so whatever else is currently eligible still reaches the branch, and the main-owned row stays queued for main's own drain.
  [`watcher-continuity.md`](watcher-continuity.md#per-actor-acknowledgement) owns the consume-side guarantee that neither actor can present or acknowledge the other's claim.
  Heartbeat keeps its own all-or-nothing recheck over the rows it can claim: it takes every branch-ownable unread row or none of them, and an unresolvable task-local row still defers the whole review to main.
  A producer can still append a row in the instant between that final check and drain startup; this accepted residual follows the confused-agent-grade boundary above rather than claiming adversarial queue isolation.
  Away mode and a broken branch between its bounded recovery probes keep today's wake-to-main behavior.

## Off-thread delivery

The supervision branch lives inside the captain's own Pi process.
Pi runs extensions, their tools, and their event handlers on the single JavaScript thread that also draws the TUI and reads the keyboard.
A synchronous subprocess in the delivery path therefore stops repaint and key echo for the child's whole lifetime.
The captain saw that as a subsecond freeze every time a routine or captain-facing outcome arrived.

Subprocess work reached through Pi's asynchronous APIs is now awaited instead.
`.pi/extensions/lib/fm-async-exec.ts` owns that awaited-spawn replacement.
It preserves the status, captured-output, and failure semantics its callers used from the synchronous form.

### The explicit delivery queue

Awaiting yields the thread, so what the single thread used to guarantee for free is now an explicit queue in `.pi/extensions/fm-branch-supervision.ts`.
Every delivery, every acknowledgement, and every turn boundary's reconciliation runs as one unit of that queue.
That queue is what preserves these guarantees:

- The durable append happens before anything visible.
- Deliveries run one at a time, in sequence order.
- The read cursor advances before the next reader sees a row.
- Each generation gets one ownership activation.

Cancellation is preserved by the generation and lock-ownership rechecks the awaits are placed around.
A session replaced mid-delivery fails the next recheck rather than acting into the session that replaced it.

### Reads that stay synchronous

Two reads stay synchronous because Pi's own API is synchronous there, not as an optimization:

- Pi types its bash spawn hook as a plain function, so the guard on the branch's own shell commands cannot await.
- The watcher reads `offer.accepted` the moment its dispatch event returns, so a session that does not own the fleet lock must still refuse a wake without waiting.

Both read the same uncached ownership authority.
The lock's process ancestry is walked in full every time it is asked, never cached.
Reparenting and pid reuse can invalidate a remembered chain, and this answer decides ownership rather than hinting at it.

## Lost-wake outcome backstop

Every main-actor wake drain checks each task's newest non-blank status event against the latest supervision-branch outcome that causally covers that task's status log.
When that event is terminal or otherwise captain-facing and remains uncovered, the drain prints it once in `STATUS OUTCOME BACKSTOP`.
It does so even if the original queue row was already acknowledged.
Routine events stay silent, and valid open decisions remain owned by `OPEN DECISIONS`.

The one-shot backstop cursor is independent from signal annotation.
A delayed signal can therefore still present its status context without repeating the recovered event.

### Bounded cost

The drain reads one fixed-size per-task outcome index instead of scanning append-only outcome history.
It inspects at most the final 64 KiB of each status log.

### Ordering limits

Status provenance added to new outcome rows distinguishes covered and genuinely later events even within one timestamp second.
Legacy outcomes predate that causal position, so equal-second migration cannot prove order.
That migration deliberately favors surfacing a plausibly later event, which can rarely duplicate an already handled legacy event.

A pathological latest status line that crosses the 64 KiB window is unclassifiable.
It remains silent rather than risking presentation of routine content.
This is an accepted limit, not a status-line size contract.

### Index repair

A missing or invalid outcome-index ready marker is rebuilt from the authoritative outcome rows by `processed-init` under the outcome lock.
That rebuild runs on the next main drain, on every harness.
Only a genuine store fault keeps that backstop skipped.

## How the branch knows what the captain said

Main's captain and assistant text - never tool calls, tool results, operational injections, or the branch's own merged notes - is mirrored into the branch as read-only `fm-main-mirror` messages.
The idle path mirrors at main's turn end.
At a prompt-bearing `before_agent_start`, Pi's authoritative prompt is staged verbatim before SessionManager persists that user entry, so the complete current captain message precedes any branch wake accepted after that boundary; the later persisted copy is suppressed and older dialog entries remain bounded.
A run Pi 1.x opens from an idle custom message carries no prompt and is never staged as captain dialog.
The mirror cursor is durable (`state/.branch-mirror-cursor`), so within one main session only not-yet-mirrored dialog is replayed.

### Re-anchoring at each main session start

Every main session start re-anchors the mirror to the current main session's start, because that start also opens a new branch conversation.
The cursor records what the PREVIOUS branch conversation received.
Without the reset, a `/resume` or reload, which keeps main's own session file, would leave the new branch blind to dialog main itself still has.
The reset is bounded by the current main session and costs only re-delivered read-only context.
The cursor keeps advancing incrementally from there.

### Mirrored text is context, not instructions

The branch prompt frames mirrored text as context for judgment, never as instructions addressed to the branch.
An authorization addressed to main (for example "you may merge when green") does not relax the branch's role limits.

## Two-stage noise filter

Stage one is unchanged: the bash watcher absorbs everything provably fine at zero token cost.
Stage two is the branch's verdict on each handled event, reported through its `fm_branch_report` tool:

| Verdict | Delivery |
| --- | --- |
| `routine` | A non-silent outcome uses the custom-message path; a silent outcome is stored without a rendered note. Neither opens a follow-up turn. |
| `captain` | Appends a versioned `fm-branch-visible-outcome` custom session entry. |

### The visible captain entry

The captain entry contains the store sequence, task, verdict, exact summary, and silent flag.
Its renderer presents the exact task and summary with an anchor prefix.

Pi custom session entries persist in the transcript but do not enter model context.
So a stale compaction summary, an unrelated assistant response, prompt caching, or model instruction noncompliance cannot acknowledge or rewrite the outcome.

The store sequence is the idempotency key.
A reload after entry persistence but before cursor advancement finds the matching entry, avoids a duplicate, and advances the cursor.
Conflicting content for one sequence fails closed.

Reconciliation runs at two points:

- At session start, when that generation already owns the fleet lock.
- At the first post-lock `turn_end`.

Together, these let a cold start that acquires the lock through the startup digest still deliver stored captain outcomes without waiting for another wake.

### Processing a captain outcome on main

Display is only half of a captain outcome.
The other half is processing, because a blocker, a decision, or a ready PR needs main to act, not only the captain to see it.

1. After the visible entry exists and the read cursor has passed it, the extension hands the oldest batch of at most 32 still-unprocessed captain rows to main as one hidden, typed `fm-branch-process` request (kind `branch-outcome`), and presents the next batch after main acknowledges that one.
   The request lists each `[seq N, recorded <age> ago] task: summary`, with the age from the store's `recordedAgo` (`bin/fm-branch-outcome.sh` owns its wording), and asks main to check the task's current state first.
   Summaries over 1024 characters are abbreviated within that bound and point to `bin/fm-branch-outcome.sh lookup --seqs <N>` for the full outcome.
   Main must read the full outcome for any abbreviated line before acting on, relaying, or acknowledging it.
   It says each outcome was recorded earlier and may already have been seen or handled, rather than claiming a visible entry in this transcript, because an outcome carried over from before a restart or a switch of primary has none here.
   Main sorts the outcomes by that state, and its reply to the captain covers only the still-open ones, as if the settled ones had never been listed; a settled one needs only the acknowledgement below.
   A listed row without a valid age breaks the store's contract, so the extension reports it to main as a visible note and sends no request; every row stays unprocessed and is presented once the store is healthy.
2. That request opens exactly one main turn.
3. Main closes it only by calling `fm_branch_processed` with the highest sequence the request listed.
   That call advances a processed marker, which `bin/fm-branch-outcome.sh` keeps separately from the read cursor and never moves past it or backwards.

A lower listed captain sequence is accepted only as a partial acknowledgement and leaves every newer captain sequence open.

Nothing else advances that marker.
An unrelated reply, an empty reply, or a reply that paraphrases the outcome leaves the sequence unprocessed.
The extension presents the current unprocessed sequence set again at the next main run boundary and at every session start.

The first presentation of a sequence set is an ordinary turn whose response stays visible, including prose alongside `fm_branch_processed`.
From the second triggered presentation of that same set on, until its listed outcomes are acknowledged, an assistant final is removed before persistence only when its text is empty after trimming or exactly matches a final already visible for that sequence set after trimming.
Differing replies stay visible, including the first real handling after an empty or unrelated reply.
Messages carrying tool calls always retain their prose, signed reasoning, and usage accounting.
Pi's Markdown transformer API buffers retry prose while streaming on versions that expose it, so the complete reply can be compared before rendering.
A retained reply renders when the message ends.
Successful acknowledgement releases subsequent assistant output, and a real user message restores ordinary output immediately, including when a processing request rides that prompt.

### Re-presentation pacing

A presentation already pending its run boundary is not resent or widened.
Once that run settles, the extension presents the then-current sequence set.

The first two presentations of a given sequence set open a turn of their own.
After that, the request rides the captain's next prompt, so an ignored request cannot become an unbounded loop of empty turns.
Changed sequence membership and a session replacement each start that budget over.

Routine outcomes never enter this path and stay turn-free.
A home with no processed marker, including an upgrade or switch from the supervision host, re-presents delivered captain rows dated and check-first until acknowledged; see the marker contract in `bin/fm-branch-outcome.sh`.

### Ownership and verdict rules

The generated [Pi supervision protocol](supervision-protocols/pi.md) owns event ownership for merged outcomes and main's acknowledgement duty.
Deterministic entry delivery owns captain visibility.

The branch prompt's "Verdict: routine or captain" section owns the classification criteria, including task-level silence eligibility and the rule to escalate doubt.

Its "PR identity: copy or abstain" section owns where a PR URL in a summary or tool argument may come from:

- The task's ready status or `pr=` metadata, verbatim.
- Otherwise, only the identifier the branch actually has.

Main can read the durable outcome store on demand through its `fm_branch_outcomes` tool.

## Heartbeat routing

The cheap bash-level heartbeat scan absorbs a genuinely no-op pass before it reaches Pi, unchanged from before.
Only a scan already flagged as possibly captain-relevant emits the bare `heartbeat` wake.
`.pi/extensions/fm-primary-pi-watch.ts` flags that offer `heartbeat: true`.
The branch accepts it without a project only when every branch-ownable row observed in the unread-queue eligibility check is one of these:

- Heartbeat-kind.
- A resolvable task-local signal or stale event.

### Co-present main-owned rows

A heartbeat is never vetoed or ridden into main by a co-present check row or decision-owned signal/stale row.
Those rows are main-owned while attended.
They are excluded from what the branch may claim and left queued for main.
Main is woken for each on its own watcher cycle, so nothing starves by being left behind.
Under the away-posture record the branch claims them too ("Postures" below).

Deferring the fleet review to main merely because some unrelated merge poll or Relay mention happened to be sitting unread put a routine review in the captain's chat for a reason that had nothing to do with the fleet.
That coupling is gone.

What all-or-nothing still guarantees is unchanged: the branch takes every branch-ownable unread row or none of them.
An unresolvable task-local row, an unknown row kind, or an unreadable queue still defers the whole review to main.

### Reporting the review

The branch runs its normal operating procedure for the wake (`bin/fm-branch-prompt.sh` "Handling a wake") and performs the deeper fleet review that main previously performed.

| Review result | Report |
| --- | --- |
| Found literally nothing worth reporting | Verdict `routine`, `task=fleet`, and `silent=true`, so it is stored without a rendered note. |
| A fleet-wide routine action | Omits `silent` and keeps its rendered sailboat note. |

Only a captain-worthy finding reports verdict `captain` and appends a visible captain outcome entry.

Every other fleet-wide or unresolvable wake keeps today's wake-to-main path in both postures.
That includes watcher-failure alarms, which are never offered to the branch.

## Cost model and the byte-stable prefix

The captain accepted the normal provider prompt-caching strategy:

- A byte-identical branch prefix generated once per firstmate version.
- The same tool set in the same order on every request.
- One shared `prompt_cache_key` per home for all branch sessions.
  It is set in a `before_provider_request` hook, and only for providers whose requests already carry that field.

Main keeps its own per-session key.

### Expected cache reuse

Budget roughly 60% cache hits on a new branch conversation's first call and 95% on later calls within that conversation.
The shared per-home key is what carries the byte-identical prefix across the conversation each main session start opens.
Reuse is best-effort, never guaranteed.

### Branch model and providers

The branch can also run on a cheaper model and a shallower reasoning effort than main, both pinned with the Pi `/supervision-model` command.
[configuration.md](configuration.md#pi-supervision-branch-model-and-effort-configsupervision-branch-model-configsupervision-branch-effort) owns those pins' operator-facing schema and unpinned behavior.

Some providers are registered by an extension only into main's runtime, such as pi-devin-auth's `devin`.
Such a provider reaches the isolated branch runtime by copying its provider config from main's captured `ModelRegistry` into the branch `ModelRuntime`.
The copy happens at model-resolution time and in the `/supervision-model` picker.
The provider's own `streamSimple` transport and OAuth wiring are thus reused by reference rather than reimplemented.

That carve-out is scoped to provider registration alone:

- The branch keeps its `noExtensions`, `noSkills`, and `noContextFiles` isolation.
- The copy is never persisted.
- A provider whose registration fails to compose is simply unavailable.

`tests/fm-pi-branch-extension.test.sh` pins the pin-and-fallthrough behavior.

### No further caching machinery

No caching machinery beyond this exists, deliberately.
Any later dynamic content in the branch prefix silently removes most of the cache benefit.
That is why `bin/fm-branch-prompt.sh`'s header is the contract's single owner and `tests/fm-branch-supervision.test.sh` pins the output to byte identity.

## Postures

One supervision session runs in two postures, attended and away.
The posture is a file: the away-posture record `state/.afk-contract`.
Only `bin/fm-afk-contract.sh` writes it, in the same turn as `/afk`.
The return path archives it on the captain's first unmarked message.

### Who reads the record

The record is never inferred from chat and never placed in the branch's byte-stable prompt prefix.
Three readers check it:

- The dispatcher reads its presence at every routing decision.
- The branch reads it at the tail of every wake and immediately before every captain-outcome presentation.
- The guarded scripts validate it through the record owner at every gate.

On Pi the away daemon is never launched, so the watcher is the single owner of supervision in both postures.
A leftover `state/.afk` flag declines nothing.

### While the record exists

- Every actionable row is branch-eligible.
  Check rows, decision-owned signal and stale rows, and heartbeat rows are claimed by the branch on whatever wake finds them unread.
  The trigger class no longer forces a batch to main.
  The fail-closed scope checks in [Decision-owned rows](#decision-owned-rows), including ambiguous metadata ownership, still apply, as does structural queue validation.
  A prompt that claims a check row is not scoped by task, so the branch may report it as `fleet`.
- Main is parked, and reachable only for the classes only main can act on:
  - A watcher-failure alarm is delivered to main as always, because `fm_watch_arm_pi` lives there.
  - A wake the branch declines or cannot take (a broken branch inside its cooldown, an unresolvable or corrupt scan) falls back to main exactly as attended.

  Parking is a cost and chat-cleanliness measure.
  Supervision continuity is the safety property, and the return brief's health section reads any gap.
- The wake message ends with a fixed `POSTURE: AWAY` tail plus the record's read-back verbatim (`bin/fm-afk-contract.sh readback`).
  The branch therefore has the captain's away words, the spend cap, the expected return, and the reach line in front of it at execution time, without any prefix change.
- Captain-verdict outcomes accumulate unprocessed in the outcome store.
  Their visible entries still persist, but no processing turn opens on the parked main.
  The request is re-checked against the record immediately before it would open and at every run boundary, so a request pending when the record appears is cancelled rather than delivered.
  If the record appears after a dedicated processing run opens, the request-local context check aborts that run; a processing request joining a user or unrelated custom run does not authorize aborting it.
  While the record exists, processing messages are filtered from request-local context, including earlier stored copies, without deleting session history or acknowledging outcomes.
  The first run boundary after the record is archived, ordinarily the captain's return message, presents the accumulated rows with a fresh triggered budget exactly as after any other gap.
  `bin/fm-afk-return.sh` lists them under "waiting on you".
- Main's standing authority relocates to the branch, and nothing more.
  [Authority relocation](#authority-relocation) below gives the details.
- The branch prompt's fixed "Postures" section states these rules once per firstmate version, so the prefix stays byte-stable.
  The per-wake tail is the only dynamic content.

### Authority relocation

`fm_lease_forbid_branch` passes the branch actor only for the actions whose guarded script opts in.
It does so only while `bin/fm-afk-contract.sh validate` succeeds on a complete, readable, live away record (`mode` is not quiet).
An archived, incomplete, invalid, or quiet record restores the attended refusal byte for byte.

The captain's away words are the whole mandate:

- The branch reads them at the tail.
- It decides by its own judgment whether the event in front of it is the moment they name.
- It acts on them only through the guarded scripts, never by analogy.
- It holds with verdict captain on doubt.

`bin/fm-branch-prompt.sh` "Postures" owns those execution rules.
It requires every action taken under the words to open its outcome summary with "per your away instructions:".

Each relocated script keeps its own gate, enforcing exactly what a script can check without reading words:

| Script | Gate while away |
| --- | --- |
| `bin/fm-pr-merge.sh` | Merges any pull request green at its live head, synchronously, under the record lock, and refuses `--allow-red`, `--allow-missing`, and `--allow-no-pipeline` while away, so the green gate is absolute in this posture; which pull request the words meant is the branch's reading. |
| `bin/fm-spawn.sh` | Dispatches only queued work whose blockers cleared - already queued, or filed by the branch because the words explicitly call for it; refuses a fresh ordinary spawn for either actor once the home holds as many ordinary task records as the record's spend cap (relaunches and secondmates exempt). |
| `bin/fm-send.sh --resolve-key` | Answers a decision the words pre-answer, or one `ask-user-authority`'s judgment (carried verbatim in the branch prompt) lets firstmate decide. |
| `bin/fm-merge-local.sh` | Never relocated. |

The merge-authority record and the outcome row's summary are the audit trail.
The return brief renders the words verbatim beside that account.

### The authority invariant

Being away changes how the captain is informed and what happens at a captain-owned decision point, never firstmate's authority set.
`tests/fm-branch-supervision.test.sh`, `tests/fm-pr-merge.test.sh`, and `tests/fm-send-resolve-key.test.sh` pin this invariant.
It sets these limits:

- The never-set (credential entry, legal or financial acceptance, an attended prompt, an unnamed discard, a security-sensitive action) has no guarded entrypoint that accepts away authority for either actor.
- A forced teardown stays refused for the branch.
- A red merge is refused in this posture whatever the words say.
- No relocation survives the return, because an archived record validates as absent and the words die with it.

### Cleanup after task completion

Ordinary cleanup of landed ships and completed scouts needs no authority relocation; [`bin/fm-branch-prompt.sh`](../bin/fm-branch-prompt.sh) owns the branch's cleanup instructions in both postures, including lease acquisition and refusal reporting.
The generated prompt includes the [scout-completion](../.agents/skills/scout-completion/SKILL.md) and [captain-hold-lifecycle](../.agents/skills/captain-hold-lifecycle/SKILL.md) policies verbatim so their completion gate reaches hosts without automatic skill loading.

## Verification

### Portable regressions

`tests/fm-pi-branch-extension.test.sh` covers:

- Dispatch, and signal and stale report scoping with unscoped heartbeat reports.
- The new branch conversation at every main session start with continuation inside one session, and the mirror re-anchor that pairs with it.
- Requested-versus-unsolicited delivery, exact visible entry content, and no unkeyed model turn.
- The sequence-keyed processing request and its acknowledgement.
- Suppression of empty or exact-repeat retry finals with differing replies preserved, preserved tool calls and user responses, the triggered-then-next-turn pacing, and session-start re-presentation.
- Routine outcomes staying turn-free, task-level no-change notes staying hidden, absent-marker re-presentation, and malformed-age reporting without acknowledgement.
- Idle and busy main state, and incident-shaped compaction and unrelated-assistant context.
- Cold-start post-lock recovery, crash-before-cursor reload recovery, and repeated-reload idempotency.
- Mirroring.
- Post-construction provider-error and no-report fallback, the consecutive-error latch, cooldown probe, exponential backoff, report-plus-settlement recovery, and report-before-error re-latch.
- Cache key, and model and effort selection.
- In `test_branch_dispatch_classifies_main_only_rows_and_writes_the_eligible_snapshot`: decision-owned signal and stale rows' exclusion from `eligibleSeqs`, their presence in `needsDecisionKeys`, task alias resolution, reserved-key configuration, status-log race and symlink refusal, non-vetoing behavior for unrelated eligible rows, and decision-only queues reading as ordinary main-only absence.
- In `test_branch_dispatch_routes_secondmate_signal_by_new_span`: second-mate signal routing by new span on the Pi and attended-host paths, including an unrelated open hold, mixed, same-key, stamped-key, key-less blocked, and resolution spans, the whole-log fallback, stale-row isolation, and crewmate routing.
- In `test_branch_dispatch_resolves_terminal_keyed_orca_stale_row`: a unique Orca `terminal=` handle resolving to its task and project in routine and heartbeat scans, and conflicting terminal, window, or task aliases refusing the whole scan in either record order.

`tests/fm-branch-supervision.test.sh` covers:

- Prompt stability, including the landed-work cleanup instruction and the second-mate relay, signal-span, and stale-liveness rules.
- The emitted completed-scout cleanup instructions and verbatim completion policies, including incomplete-work boundaries and refusal reporting; these assertions verify prompt delivery, not a model's adherence.
- Store append-only behavior, the captain cursor barrier, processed-marker sequence bounds and absent-marker safety, and captain-only recorded ages.
- Leases, guards, and non-branch-home invariance.
- The away relocation: only under a valid live record, never for local-only landing, queued-only branch dispatch rather than orphaned in-flight recovery, the spend cap for both actors and its lock-held recheck, and the attended guarded-action behavior restored by archive or an invalid record.

`tests/fm-afk-return.test.sh` covers the ordered cleanup-due section, its durable merge-marker requirement, and exclusion of both a done task without durable merge evidence and a persistent secondmate carrying that evidence.

`tests/fm-pr-merge.test.sh` covers the branch actor merging a green task under the record, being refused on a red check, an unreported required check, or `--allow-red`/`--allow-missing` under it, and being refused at the partition while attended.

`tests/fm-secondmate-safety.test.sh` covers the branch actor being refused second-mate retirement with the mate's record, home, route, and endpoint left intact.

`tests/fm-send-resolve-key.test.sh` covers the decision-answer partition:

- A needs-decision or captain-held key refuses the attended branch before anything is sent.
- A `blocked:` key stays ordinary steering.
- The record relocates the answer.

For the away posture:

- `tests/fm-pi-watch-extension.test.sh` covers the away eligibility collapse (check-kind and decision-owned triggers offered) with the broken-queue vetoes and the watcher-failure alarm still reaching main.
- `tests/fm-pi-branch-extension.test.sh` covers the posture tail with the verbatim read-back, the unscoped claim of check and heartbeat rows, no processing turn under the record, cancellation of a request pending when the record appears, and the re-presentation at the first run boundary after archive.

`tests/fm-wake-drain-outcome-backstop.test.sh` covers keyless resurfacing, causal suppression, same-second ordering, one-shot presentation, first-drain index self-healing under the outcome lock, store-fault fail-closed behavior, bounded history cost and output, and the oversized-line limit.

`tests/fm-teardown.test.sh` covers removal of the retired task's outcome index and the append-side rule that a post-teardown report does not recreate it.
The branch-offer, heartbeat-offer, heartbeat-not-ridden-by-main-only-rows, main-only-check-class, captain-held-stale-stays-on-main, and mixed-signal-routing tests remain in `tests/fm-pi-watch-extension.test.sh` (the last two routing classes exercise `offerWakeToBranch`'s trigger-key cross-reference end to end), the recovery test remains in `tests/fm-session-start.test.sh`, and the per-actor consume regression remains in `tests/fm-wake-queue.test.sh`.
It also covers the off-thread delivery contract behaviorally: that a delivery leaves the event loop running rather than blocking it, that interleaved reports stay ordered and exactly once, that a session replaced mid-delivery neither loses nor duplicates an outcome, and that a failing store script surfaces without losing or doubling one.
`tests/fm-watch-triage.test.sh` covers `bin/fm-watch.sh`'s side of the contract end to end: needs-decision, no-verb captain-held, and pending-reply second-mate escalation signal rows are marked `needs-decision:`, a needs-decision whose key transition was rejected by the reserved-key vocabulary (`fm-classify-lib.sh`'s `reconciliation-required:` wrapper) is still marked, and ordinary blocked or captain-relevant signals stay unmarked.
`tests/fm-branch-dispatch-signal-paths.test.sh` covers batch-row resolution from `state/.signal-batch-paths`, the legacy payload fallback for a row with no record, and the missing-record veto that surfaces a compact summary row to main.
Live guards: `FM_PI_BRANCH_LIVE_E2E=1 tests/fm-pi-branch-live-e2e.test.sh` exercises the real installed Pi SDK's immediate active-transcript appendEntry rendering, persistence, custom-entry model exclusion, branch-session surfaces, and watcher-owned fallback after rejected branch settlement.
`FM_PI_BRANCH_RESPONSIVENESS_E2E=1 tests/fm-pi-branch-responsiveness-live-e2e.test.sh` answers the question only a real TUI can: it types into an isolated Pi pane while outcomes are delivered and fails if keystroke echo leaves the class of the same machine's extension-free floor.
Record dated current results in [docs/verification/runtime-backends.md](verification/runtime-backends.md).
The [strict production-consumer typecheck](../tests/fm-pi-primary-types.test.sh) owns its pinned SDK/compiler matrix and temporary dependencies independently of the installed Pi runtime.
