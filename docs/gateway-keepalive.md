# Inference-gateway keep-alive

Firstmate agents run against an inference gateway that pools accounts.
When no pooled account is routable the gateway answers 503, the harness ends the turn with an API error, and the agent is left idle at its prompt with its work unfinished.
Nothing in the harness resumes it.
Before this keep-alive existed, that agent sat there until a human noticed and told it to carry on, and the supervisor read the same idle pane as a possible wedge.

This is the authoritative contract for how firstmate keeps agents working across those stalls.
`bin/fm-gateway-retry-lib.sh` is the single owner of the classifier, the durable stall record, and both bounds; its header owns the exact record format and tunables.

## Why the agent cannot fix this itself

Claude Code reports an API-error turn end through `StopFailure`, not `Stop`, and it executes `StopFailure` hooks outside its REPL loop and discards their result.
A `StopFailure` hook therefore has no way to block the stop or force a continuation, unlike the `Stop` hooks [`turnend-guard.md`](turnend-guard.md) describes.
The keep-alive is built on that fact rather than around it: the stall is detected from the rendered pane by an actor outside the session, and that actor delivers the nudge.
[`verification/gateway-keepalive.md`](verification/gateway-keepalive.md) records the live evidence.

## What counts as a transient gateway stall

The rendered pane is the single detector, for every actor.
It is the one signal that keeps saying "still stalled" for as long as the stall lasts, and it is the only signal a reader outside the session has.

The transient match reads only the few non-blank lines immediately above the harness's prompt and footer, which is where a turn-ending API error renders, and it matches only the harness's rendered `API Error: <5xx>` shape.
That bounded window is the same footer window the watcher's busy match reads, and for the same reason: an agent that recovered and went idle again with the old error still in its scrollback must not be re-rung.
`FM_GATEWAY_TAIL_LINES` sizes the window.

Inside that window the match is anchored to the pane's **live output line**: the last row that is rendered output, which is the row the agent's last turn ended on.
The composer and everything the harness draws below it are skipped first — they are not output, and the raw last non-blank row of an idle pane is the shortcut footer, so anchoring there would blind the detector.
The shape is also not matched when that row quotes it inside backticks or quotation marks.
Both rules exist because an agent that merely printed this repository's own sources must not be re-rung either: the docs, the tests and the classifier itself carry the literal rendered string, so a crewmate that read them ends its turn with the shape on screen.
A citation always carries something around it, either more output below it or a quote beside it; the harness's own turn-ending error carries neither.
Re-ringing a healthy crew is not a harmless nudge — it spends the whole budget and stamps a false `paused [key=gateway-503]` on that crew's status log, which then routes a genuinely wedged pane onto the long declared-wait cadence instead of the wedge timer.

A deny list runs first, over the whole capture, and beats the transient match.
It exists because the non-retryable failures are the expensive mistakes: a prompt that is too long, an expired credential, or a spent usage limit cannot be improved by asking the agent to carry on, and one real failure this fleet produces (`Prompt is too long · automatic compaction failed: API Error: 503 ...`) carries a 503 inside a failure that is not the gateway's.
A gateway that is simply unreachable is deliberately outside the transient class too: that is the genuine outage, and it should surface rather than be papered over.

## How an agent is kept alive

1. **Detect.** The actor that reads the idle agent's pane classifies its tail and opens a durable stall record on the first sighting.
   A pane that no longer shows the error is a recovered agent, and its record is dropped so a later stall starts fresh.
   That reading only happens on a poll that finds the agent idle, so a record is also dropped once its pane has read busy continuously for `FM_GATEWAY_BUSY_CLEAR_SECS`: an agent that took the continue and then worked for that long has recovered, and must not carry a half-spent ladder and a stale horizon anchor into the next, unrelated stall.
   Busy alone is not the signal - the continue this ladder sends makes the pane busy until the turn ends, and a turn that dies on the next error is busy for the harness's whole internal retry, about four minutes on the version verified in [`verification/gateway-keepalive.md`](verification/gateway-keepalive.md), so ending the record there would wipe the attempt count mid-ladder and no genuine outage could ever be declared.
   The threshold is therefore set well past that verified retry, so the ladder's own retry can never reach it, and it is held in seconds and converted to whatever cadence the watcher actually polls at - a poll-denominated bound would shrink back under the retry on a home that polls faster.
2. **Re-ring.** The same actor sends the agent one continue instruction.
   For a crewmate or scout that is the watcher (`gateway_stall_check` in `bin/fm-watch.sh`), which delivers through the steering inbox as a fire-and-forget record: durable and rung with the constant doorbell, but excluded from the inbox's own re-ring ladder, because during a real outage the crew cannot acknowledge anything and an ordinary steer left unhandled would be escalated into stuck-crewmate recovery, the wedge treatment this keep-alive exists to avoid.
   For the primary session it is the keep-alive agent below.
3. **Bound.** Every re-ring is charged against a record bounded twice: an attempt count and a wall-clock horizon.
   Either bound alone is insufficient, because one stops a fast loop and the other stops a slow one spread across a real outage.
   The gateway ladder owns every re-ring and both bounds; nothing else re-rings the record.
4. **Declare.** When either bound is spent, the stall stops being re-rung and is declared once as an external wait (`paused [key=gateway-503]: ...`), so the pane takes the long declared-wait cadence instead of a wedge escalation.
   That declaration is closed (`resolved [key=gateway-503]: ...`) at the transition that proves it is over - the pane recovering, which drops the record that declared it - so a crew that carries on is not left reported as still waiting on the gateway.

A successful re-ring is silent.
An agent that carries on is not news, and the whole point is that the captain stops being the retry mechanism.

## Watcher backstop

The watcher's check runs on every idle recorded window and costs one classification of a pane it already captured.
It is deliberately not gated on the wedge timer's "nothing changed for two polls" rule: the evidence here is a specific rendered failure, not an absence of change, so an agent is re-rung promptly rather than after the stale bookkeeping has accumulated.
Because it lives in the watcher, every agent already running gets the behaviour without being relaunched.

Secondmate endpoints are outside it.
An idle secondmate pane is healthy by design and is admitted to the stale path only to serve a declared wait, so it is never read for a stall; `gateway_stall_check` refuses a secondmate outright rather than piggybacking on that admission.
A secondmate's own home runs its own watcher for its crews, and that is where they are kept alive.

## Tuning

`bin/fm-gateway-retry-lib.sh`'s header owns the full list.
The ones worth knowing: `FM_GATEWAY_RETRY_MAX` (default 8 attempts), `FM_GATEWAY_RETRY_HORIZON` (default 2700 seconds), `FM_GATEWAY_RETRY_BACKOFF` (default `30 60 120 300`, last step repeating), `FM_GATEWAY_TAIL_LINES` (default 10 non-blank lines above the footer), and `FM_GATEWAY_BUSY_CLEAR_SECS` (default 600 seconds of continuous busy end a record, at any poll interval).

## Regression coverage

`tests/fm-gateway-keepalive.test.sh` covers the classifier against the exact rendered strings this fleet's transcripts contain, bare and above the idle composer and footer; the deny list beating a transient code inside a permanent failure and matching anywhere while the transient match stays bounded; a recovered agent whose scrollback still holds the old error and repository text naming the errors both staying out of the ladder; each bound independently; the anchor stability that keeps a frequently polled stall from being absorbed forever; and the pane as the single detector.
`tests/fm-watch-triage.test.sh` drives a real watcher over a stalled pane and asserts the continue instruction lands in the steering inbox as a fire-and-forget record without a wake, that a spent budget declares the external wait and stops re-ringing, that the harness's own internal 503 retry keeps the record and still reaches a declared outage while a busy stretch reaching the threshold drops it so a later transient error starts a fresh ladder, and that a paused secondmate whose pane shows the error is re-surfaced as a paused mate and never re-rung.
`tests/fm-busy-adapter-wiring.test.sh` pins that the spawn-written Claude settings register the busy writer alone on `StopFailure`.
`tests/fm-teardown.test.sh` pins that a retired task leaves no stall record behind to poison the next task reusing its id.
