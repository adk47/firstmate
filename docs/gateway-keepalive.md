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
The keep-alive is built on that fact rather than around it: the hook is a detector, and something outside the session delivers the nudge.
[`verification/gateway-keepalive.md`](verification/gateway-keepalive.md) records the live evidence.

## What counts as a transient gateway stall

Two independent signals, either of which can carry a positive verdict, because each is the only signal one of the detectors has:

- The harness's typed error kind, a closed enum, of which `overloaded` and `server_error` are the transient gateway class.
  Only the `StopFailure` payload carries it.
- The rendered error text: the `API Error: <5xx>` shape and the gateway's own out-of-capacity sentences.
  A pane reader has nothing else.

A deny list runs first and beats both.
It exists because the non-retryable failures are the expensive mistakes: a prompt that is too long, an expired credential, or a spent usage limit cannot be improved by asking the agent to carry on, and one real failure this fleet produces (`Prompt is too long · automatic compaction failed: API Error: 503 ...`) carries a 503 inside a failure that is not the gateway's.
A gateway that is simply unreachable is deliberately outside the transient class too: that is the genuine outage, and it should surface rather than be papered over.

## How an agent is kept alive

1. **Detect.** The `StopFailure` hook `bin/fm-gateway-stall-hook.sh` opens a durable stall record the instant the turn fails.
   It is registered for every Claude crewmate and scout by `bin/fm-spawn.sh`, and for the primary session in the tracked `.claude/settings.json`.
   It only records: it never blocks, never sleeps, and always exits 0.
2. **Re-ring.** The actor that can reach the idle agent sends it one continue instruction.
   For a crewmate or scout that is the watcher (`gateway_stall_check` in `bin/fm-watch.sh`), which delivers through the ordinary steering inbox, so the message is durable, re-rung, acknowledged, and escalated by the same ladder as any other firstmate instruction.
   For the primary session it is the keep-alive agent below.
3. **Bound.** Every re-ring is charged against a record bounded twice: an attempt count and a wall-clock horizon.
   Either bound alone is insufficient, because one stops a fast loop and the other stops a slow one spread across a real outage.
4. **Declare.** When either bound is spent, the stall stops being re-rung and is declared once as an external wait (`paused [key=gateway-503]: ...`), so the pane takes the long declared-wait cadence instead of a wedge escalation.

The rendered pane is authoritative once an attempt has been charged.
The hook's record alone holds the ladder open only before the first attempt, which is exactly the gap between the harness failing the turn and the next poll rendering it.
After that, an agent whose pane has moved on is working again and leaves the ladder, so a recovered agent is never interrupted by a late nudge.

A successful re-ring is silent.
An agent that carries on is not news, and the whole point is that the captain stops being the retry mechanism.

## Watcher backstop

The watcher's check runs on every idle recorded window and costs one classification of a pane it already captured.
It is deliberately not gated on the wedge timer's "nothing changed for two polls" rule: the evidence here is a specific rendered failure, not an absence of change, so an agent is re-rung promptly rather than after the stale bookkeeping has accumulated.
Because it lives in the watcher rather than only in a hook, every agent already running gets the behaviour without being relaunched.

Secondmate endpoints are outside it.
An idle secondmate pane is healthy by design and is admitted to the stale path only to serve a declared wait, so it is never read for a stall.
A secondmate's own home runs its own watcher, and that is where its crews are kept alive.

## Primary keep-alive agent

Everything else that notices trouble runs inside the primary session, or inside a process the primary session started.
A primary that is itself stalled at its prompt therefore has nobody to notice.
`bin/fm-keepalive-agent.sh` is the supervisor of the supervisor: one bounded pass, run from launchd, outside all of it.

Each pass stops at the first condition that applies:

1. The primary's pane is idle showing a transient gateway error: re-ring it on the same bounded ladder.
2. The primary's session is not running: report it and stop.
3. Supervision has lapsed - the beacon is stale past grace with work in flight, no auto-arm is in progress, and away mode is not active: send the home's own repair line, which [`../bin/fm-supervision-instructions.sh`](../bin/fm-supervision-instructions.sh) owns, so the session performs the repair its protocol prescribes.

It never relaunches firstmate, never interrupts, never touches another home, and never acts on a pane it cannot prove is this home's primary.
Those are not caution for its own sake: it runs unattended with no session lock and nobody watching, so anything it does wrong it does repeatedly and invisibly.
Reporting a dead session and letting a human restart it is the right outcome for the one case where guessing would be worst.

Knowing which pane is the primary is the part that needs care.
Every other endpoint firstmate supervises was written into `state/<id>.meta` by the spawn that created it; the primary was not spawned by firstmate, and launchd starts the agent with none of the pane environment a process started from that pane would inherit.
`bin/fm-keepalive-endpoint.sh` records what the session itself can prove into `state/.primary-endpoint`, the installer captures it, and the primary's own `StopFailure` hook refreshes it, so a firstmate relaunched into a different pane re-points the agent without a reinstall.
When nothing proves an endpoint, the agent stays inert and says so.

## Installing it

Opt-in, and never installed for you.
It writes into the captain's own `LaunchAgents` directory and then runs unattended, which is not a change firstmate makes on its own initiative, so nothing in session start, bootstrap, or self-update calls it.

Run this **from the primary firstmate pane**, which is the only place the session's own endpoint can be observed:

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
On any other platform the installer refuses and names the systemd user timer or cron entry it will not write for you.

## Tuning

`bin/fm-gateway-retry-lib.sh`'s header owns the full list.
The ones worth knowing: `FM_GATEWAY_RETRY_MAX` (default 8 attempts), `FM_GATEWAY_RETRY_HORIZON` (default 2700 seconds), and `FM_GATEWAY_RETRY_BACKOFF` (default `30 60 120 300`, last step repeating).

## Regression coverage

`tests/fm-gateway-keepalive.test.sh` covers the classifier against the exact rendered strings this fleet's transcripts contain, both independent positives and both permanent vetoes, the deny list beating a transient code inside a permanent failure, each bound independently, the anchor stability that keeps a frequently polled stall from being absorbed forever, pane authority after the first attempt, and the detector hook's inert, clearing, and always-exit-0 behaviour.
`tests/fm-watch-triage.test.sh` drives a real watcher over a stalled pane and asserts the continue instruction lands in the steering inbox without a wake, then that a spent budget declares the external wait and stops re-ringing.
`tests/fm-busy-adapter-wiring.test.sh` drives the detector through the settings file `fm-spawn` actually wrote, pinning that it stays its own `StopFailure` entry rather than being chained behind the busy writer, where it would race for the payload on stdin.
`tests/fm-teardown.test.sh` pins that a retired task leaves no stall record behind to poison the next task reusing its id.
`tests/fm-turnend-guard.test.sh` pins the primary registration in the tracked settings inventory.
