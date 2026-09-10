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
That bounded window is the same footer window the watcher's busy match reads, and for the same reason: an agent that recovered and went idle again with the old error still in its scrollback must not be re-rung, and an agent that merely printed this repository's own sources at its prompt must not be either.
`FM_GATEWAY_TAIL_LINES` sizes the window.

A deny list runs first, over the whole capture, and beats the transient match.
It exists because the non-retryable failures are the expensive mistakes: a prompt that is too long, an expired credential, or a spent usage limit cannot be improved by asking the agent to carry on, and one real failure this fleet produces (`Prompt is too long · automatic compaction failed: API Error: 503 ...`) carries a 503 inside a failure that is not the gateway's.
A gateway that is simply unreachable is deliberately outside the transient class too: that is the genuine outage, and it should surface rather than be papered over.

## How an agent is kept alive

1. **Detect.** The actor that reads the idle agent's pane classifies its tail and opens a durable stall record on the first sighting.
   A pane that no longer shows the error is a recovered agent, and its record is dropped so a later stall starts fresh.
2. **Re-ring.** The same actor sends the agent one continue instruction.
   For a crewmate or scout that is the watcher (`gateway_stall_check` in `bin/fm-watch.sh`), which delivers through the steering inbox as a fire-and-forget record: durable and rung with the constant doorbell, but excluded from the inbox's own re-ring ladder, because during a real outage the crew cannot acknowledge anything and an ordinary steer left unhandled would be escalated into stuck-crewmate recovery, the wedge treatment this keep-alive exists to avoid.
   For the primary session it is the keep-alive agent below.
3. **Bound.** Every re-ring is charged against a record bounded twice: an attempt count and a wall-clock horizon.
   Either bound alone is insufficient, because one stops a fast loop and the other stops a slow one spread across a real outage.
   The gateway ladder owns every re-ring and both bounds; nothing else re-rings the record.
4. **Declare.** When either bound is spent, the stall stops being re-rung and is declared once as an external wait (`paused [key=gateway-503]: ...`), so the pane takes the long declared-wait cadence instead of a wedge escalation.

A successful re-ring is silent.
An agent that carries on is not news, and the whole point is that the captain stops being the retry mechanism.

## Watcher backstop

The watcher's check runs on every idle recorded window and costs one classification of a pane it already captured.
It is deliberately not gated on the wedge timer's "nothing changed for two polls" rule: the evidence here is a specific rendered failure, not an absence of change, so an agent is re-rung promptly rather than after the stale bookkeeping has accumulated.
Because it lives in the watcher, every agent already running gets the behaviour without being relaunched.

Secondmate endpoints are outside it.
An idle secondmate pane is healthy by design and is admitted to the stale path only to serve a declared wait, so it is never read for a stall; `gateway_stall_check` refuses a secondmate outright rather than piggybacking on that admission.
A secondmate's own home runs its own watcher for its crews and its own session-start keep-alive for its primary, and that is where they are kept alive.

## Primary keep-alive agent

Everything else that notices trouble runs inside the primary session, or inside a process the primary session started.
A primary that is itself stalled at its prompt therefore has nobody to notice.
`bin/fm-keepalive-agent.sh` is the supervisor of the supervisor: one bounded pass, run from launchd, outside all of it.

Each pass stops at the first condition that applies:

1. The primary's pane is idle showing a transient gateway error: re-ring it on the same bounded ladder.
   Idle is decided by the same rendered busy predicate every other pane reader uses, so a primary the captain already nudged and that is mid-turn is never typed into.
2. The primary's session is not running: report it and stop.
   `state/.lock` holds the bare pid `bin/fm-lock.sh` wrote, and liveness is the shared harness predicate its other readers use, so a reused pid that is no longer a harness is not a live session.
3. Supervision has lapsed - the beacon is stale past grace with work in flight, no auto-arm is in progress, and away mode is not active: send the home's own repair line, which [`../bin/fm-supervision-instructions.sh`](../bin/fm-supervision-instructions.sh) owns, so the session performs the repair its protocol prescribes.

It never relaunches firstmate, never interrupts, never touches another home, and never acts on a pane it cannot prove is this home's primary.
Those are not caution for its own sake: it runs unattended with no session lock and nobody watching, so anything it does wrong it does repeatedly and invisibly.
Reporting a dead session and letting a human restart it is the right outcome for the one case where guessing would be worst.

Knowing which pane is the primary is the part that needs care.
Every other endpoint firstmate supervises was written into `state/<id>.meta` by the spawn that created it; the primary was not spawned by firstmate, and launchd starts the agent with none of the pane environment a process started from that pane would inherit.
`bin/fm-keepalive-endpoint.sh` records what the session itself can prove into `state/.primary-endpoint`, and the main home's session start refreshes it from the lock-owning primary's own environment, so a firstmate relaunched into a different pane re-points the agent without a reinstall.
When nothing proves an endpoint, the agent stays inert and says so.

## Installing it

The main home installs it for you.
`bin/fm-bootstrap.sh`'s `primary_keepalive_setup` runs in the locked mutating sweep of every session start, so it never fires from a lock-refused session or a child worktree, and it is scoped three ways: the main home only, a genuine primary checkout only, and the session that actually holds this home's fleet lock only, so a scratch session opened at the repo root can never record its own pane as the primary.
It refreshes `state/.primary-endpoint` from the session's own environment, installs the launchd job only when it is absent, and stays quiet when the job is already installed and pointed at this pane.
It prints exactly one `BOOTSTRAP_INFO: primary keep-alive installed ...` or `... refreshed ...` fact when it did either; that line is a completed no-action fact, never an actionable diagnostic.
A failed install never fails session start.

To opt the home out, create `config/keepalive-off`; the sweep then does nothing at all.
Secondmate homes are opt-in exactly as before: run the installer by hand **from that home's primary pane**, which is the only place the session's own endpoint can be observed:

```
bin/fm-keepalive-install.sh install
bin/fm-keepalive-install.sh status
bin/fm-keepalive-install.sh uninstall
```

`--interval` accepts 60 to 3600 seconds and defaults to 240.
`--backend` and `--target` override endpoint discovery for a terminal whose identifiers this build cannot read from the environment; the install refuses rather than guessing when neither discovery nor an override supplies one.
The job is per-home: its launchd label carries a digest of the home path, it passes that home explicitly, and every artifact it writes lives under that home's state directory, so a secondmate home's job and the main home's job cannot disturb each other.
Its log is `state/.keepalive-agent.log`, size-capped.

launchd is macOS only.
On any other platform the session-start sweep does nothing, and the installer refuses and names the systemd user timer or cron entry it will not write for you.

## Tuning

`bin/fm-gateway-retry-lib.sh`'s header owns the full list.
The ones worth knowing: `FM_GATEWAY_RETRY_MAX` (default 8 attempts), `FM_GATEWAY_RETRY_HORIZON` (default 2700 seconds), `FM_GATEWAY_RETRY_BACKOFF` (default `30 60 120 300`, last step repeating), and `FM_GATEWAY_TAIL_LINES` (default 10 non-blank lines above the footer).

## Regression coverage

`tests/fm-gateway-keepalive.test.sh` covers the classifier against the exact rendered strings this fleet's transcripts contain, bare and above the idle composer and footer; the deny list beating a transient code inside a permanent failure and matching anywhere while the transient match stays bounded; a recovered agent whose scrollback still holds the old error and repository text naming the errors both staying out of the ladder; each bound independently; the anchor stability that keeps a frequently polled stall from being absorbed forever; the pane as the single detector; and the keep-alive agent's sends and refusals over a fake backend, with `state/.lock` seeded as the bare pid the lock really holds.
The same file drives the real `bin/fm-bootstrap.sh` over a genuine primary checkout with a fake launchd and process table, pinning the one-time install, the quiet already-installed session start, the refresh on relaunch, the `config/keepalive-off` opt-out, and the macOS, main-home, lock-ownership, and detect-only scopes.
`tests/fm-watch-triage.test.sh` drives a real watcher over a stalled pane and asserts the continue instruction lands in the steering inbox as a fire-and-forget record without a wake, that a spent budget declares the external wait and stops re-ringing, and that a paused secondmate whose pane shows the error is re-surfaced as a paused mate and never re-rung.
`tests/fm-busy-adapter-wiring.test.sh` pins that the spawn-written Claude settings register the busy writer alone on `StopFailure`.
`tests/fm-teardown.test.sh` pins that a retired task leaves no stall record behind to poison the next task reusing its id.
