# Supervisor failover: Fable to Grok, and back

This runbook rehearses and performs two handoffs on this firstmate home, and the lane-side backup that keeps the workers running while the supervisor is out of Fable:

- **Failover**: move the primary firstmate supervisor from a Claude Code session on Fable to a Grok-run firstmate session in the same home.
- **Fail-back**: return the supervisor to Claude Code on Fable when the account pool regains a Fable-capable account.
- **Lane-side backup**: move Claude Code work lanes onto the DeepSeek gateway route, in place, so they keep their crons and `/loop` ticks while the Claude pool is thin.

The monitor and the wake that starts this are owned by [`fm-fable-runway.sh`](../../bin/fm-fable-runway.sh) and [`fm-fable-runway-check.sh`](../../bin/fm-fable-runway-check.sh); [`docs/configuration.md`](../configuration.md) "Fable runway monitor" owns arming, thresholds, and the wake contract.
This runbook owns the procedures themselves.

## 1. The two runways and the wake that starts this

Two independent things can run out, and they do not fail together:

- The **supervisor's own credential** (`fable_state`), read from `quota-axi`'s `model:fable` window.
- The **account pool** `better-ccflare` serves from (`pool_state`), read from the local gateway's `/health` and `/api/accounts`.

At GREEN nothing to do.
At YELLOW, plan the move and make sure Grok has fuel.
At RED, execute one of the handoffs below.
A RED overall state is always accompanied by at least one `fable_state=RED` or `pool_state=RED` token in the wake, so which runway failed is never ambiguous.

The check never switches anything.
It reports, and the supervisor acts.
The lane-side switch in Part 4 is also a firstmate action: run it deliberately, one lane at a time.

## 2. Before the day it is needed

Do not rehearse under RED.
The whole point of the drill in Part 5 is that the Red condition is reachable while Fable still has headroom.
Read the current state with `bin/fm-fable-runway.sh` and record it in the drill log.

Grok needs runway too.
`quota-axi --provider grok` reports its window; keep it above roughly 30 percent before starting a drill or a real failover.

## Part 1 - Fail the supervisor over to Grok

### 1.1 Preconditions

- No lane is mid `no-mistakes` run.
- No incident is open.
- `bin/fm-lock.sh status` shows the current holder, and it is the Claude primary you are about to stand down.
- Only one gateway serves the Claude pool.
  Grok does not consume the Claude pool itself, but do not point a second gateway at the same accounts.

### 1.2 Warm Grok without taking the seat

From the firstmate home directory, launch Grok in a second terminal surface:

```
grok --trust
```

`--trust` is required for the tracked `.grok/hooks/` primary hooks to load, and this home is already in `~/.grok/trusted_folders.toml`.
Confirm the warm session proves the plumbing without taking over:

- Its SessionStart path prints the session-start nudge.
  Grok discards hook stdout from model context, so this is the nudge tier, not the run tier; the digest is delivered as an instruction the session must run.
- Running `bin/fm-session-start.sh` from the warm session refuses the session lock, because the Claude primary still holds it, and the session stays read-only.

This proves the hook plumbing, the nudge tier, and the lock refusal before any handoff.

### 1.3 Prove one Grok supervision cycle on the read-only session

Arm the watcher from the warm session exactly as [`docs/supervision-protocols/grok.md`](../supervision-protocols/grok.md) tells it to: one `run_terminal_command` call with `background: true` running

```
[ -f state/x-mode.env ] && . state/x-mode.env; exec bin/fm-watch-arm.sh
```

A `watcher: started ...` or `watcher: attached ...` line means a live cycle exists.
Do not use a shell `&`, and do not bundle the arm onto another command; the PreToolUse seatbelt refuses both.

### 1.4 Hand the seat over

1. In the Claude primary, finish the current turn. Do not interrupt a running validation.
2. Exit the Claude session (`/exit`).
3. Verify the lock is released: `bin/fm-lock.sh status` should read `lock: stale (pid <n> dead or not a harness)` or `lock: free`.
   The lock is a live-integer record, so a dead holder is stale and reclaimable; `bin/fm-lock.sh` owns the staleness rule.
4. In the warm Grok surface, run `bin/fm-session-start.sh`.
   It now acquires the lock and prints the full digest.
   Confirm the digest appears and the wake queue drains.
5. Arm the next supervision cycle with the background call from 1.3 and confirm `watcher: started` or `watcher: attached`.

### 1.5 Prove the loop end to end

Force one real wake by appending a `working:` line to a live task's status file, then confirm the Grok session drains it, handles it, and re-arms after the actionable close.
A handoff that has not drained a real wake is not proven.

### 1.6 What is different while Grok holds the seat

- The Claude Stop `asyncRewake` auto-arm (`bin/fm-claude-stop-autoarm.sh`) no longer runs, because the Claude session is gone.
  Grok supervision is instead a tracked background task that the session must re-arm after each actionable cycle; a cycle that ends without a wake leaves supervision down until the next arm.
- The turn-end backstop is [`bin/fm-turnend-guard-grok.sh`](../../bin/fm-turnend-guard-grok.sh) through `.grok/hooks/fm-primary-turnend-guard.json`; [`docs/turnend-guard.md`](../turnend-guard.md) owns its adaptive continuation.
- Session start is the nudge tier rather than the run tier; see [`docs/sessionstart-nudge.md`](../sessionstart-nudge.md).
- The Bash PreToolUse seatbelt comes from `.grok/hooks/fm-primary-pretool-check.json`; the tracked Claude entries stand down under Grok's hook markers.
- Everything durable is unchanged: `data/`, `state/`, the wake queue, held decisions, and in-flight workers all live on disk.
  Worker agents keep their own backend sessions and keep working; the new supervisor reconciles them from `state/*.meta` and `state/<id>.status` exactly as the old one did.

Treat Grok as a degraded-but-working supervisor for the re-arm burden, not a like-for-like replacement.

## Part 2 - Hand the seat back to Claude Code

1. In the Grok session, finish the turn and `/exit`.
2. Verify the lock: `bin/fm-lock.sh status`.
3. Relaunch Claude Code in the firstmate home on the original session:

```
claude --dangerously-skip-permissions --resume <session-id>
```

The session id is the one the previous `/exit` printed, and it is also visible in the recorded lock holder's command line while Claude held the seat.
4. Confirm the Claude Stop hook reclaims supervision: the next Stop fires `bin/fm-claude-stop-autoarm.sh`, which arms the watcher only while work is in flight and this session holds the lock.
5. Confirm no wake was lost: `state/.wake-queue` is empty and no `RECORD DIVERGENCE` line prints at the next drain.
6. Confirm the supervisor is on Fable and the pool: `~/.claude/settings.json` pins the model and `ANTHROPIC_BASE_URL=http://127.0.0.1:8080`.

## Part 3 - Fail back to Fable when the pool recovers

The fail-back signal is the check's recovery line:

```
fable-runway: capacity back account=<name> ... pool_state=<S> ...
```

It fires when an account the pool tracked but could not use is usable again, which is normally a per-account Fable window reset.
An account newly added to the pool is not a recovery and is never named here.
The label reads the same however far the pool recovered; read `pool_state=` on the same line to see whether the pool is back to `GREEN` or still thin at `YELLOW`.

Procedure:

1. Confirm the named account is genuinely Fable-capable and routable: `curl -s http://127.0.0.1:8080/health` reports a healthy `pool.routable`, and `bin/fm-fable-runway.sh` reports `pool_state=GREEN`.
2. If the supervisor is on Grok, hand the seat back with Part 2.
3. If the supervisor never left Claude Code but its own credential was the RED runway, no handoff is needed; the pool account is now serving the primary again.
4. Leave the lanes where they are.
   The captain's standing preference is that workers keep running on the DeepSeek gateway route once moved; fail-back returns the supervisor to Fable, not the lanes.
   Bring a lane back only on an explicit decision, using Part 4.4.
5. Re-run `bin/fm-fable-runway.sh` and record the recovered states in the drill log.

## Part 4 - Lane-side backup: move Claude Code lanes to DeepSeek

At RED, or whenever `pool_routable` is at or below the YELLOW line, offload lanes to the DeepSeek gateway route.
The move is in place, inside Claude Code, so crons, `/loop` wakeups, skills, and hooks survive.
Never relaunch a lane on Pi for this: Pi has no `/loop` or cron surface, and a lane that depends on one would silently go idle.

### 4.1 Pick the provider from the existing router

Do not invent a provider choice. `~/.config/llm-route/pick.py` is the single owner of that rule, and it is clock-driven with no network:

```
python3 ~/.config/llm-route/pick.py deepseek
```

Off-peak it selects OpenRouter's `deepseek/deepseek-v4.1-flash`; at DeepSeek's own price peak (weekdays 01:00-04:00 and 06:00-10:00 UTC) it selects Fireworks' `accounts/fireworks/models/deepseek-v4p1-flash`, which is flat-priced.
`pick.py --json` gives the same choice in machine form.

### 4.2 The gateway route

The proven route is a local Anthropic-compatible gateway that advertises the DeepSeek model ids on `GET /v1/models`, so Claude Code discovers them and accepts `/model`:

```
curl -s -H "Authorization: Bearer <local-token>" http://127.0.0.1:8799/v1/models
```

Claude Code caches the discovery response to `<config-dir>/cache/gateway-models.json`, which is why an advertised id becomes selectable in `/model`.
Pointing Claude Code straight at a public provider base URL does not work; the client's model catalog refuses the id before any request leaves the machine.

### 4.3 Move one lane, in place

Do this one lane at a time, and start just after the lane's own tick so a missed tick is visible immediately.

1. Read the lane's endpoint and current composer from its `state/<id>.meta`, and capture whatever is typed.
2. Interrupt to clear the composer (`Ctrl+C`), then verify the composer is empty. Never send a `/model` line into a composer you have not verified empty.
3. Send the switch, for example `/model deepseek-v4.1-flash` (or the Fireworks id `pick.py` selected).
4. Verify the switch landed in the lane's footer or `/model` list.
5. Wait for the lane's next tick and confirm it fires.
6. Confirm the gateway recorded the switch and the real cost, not the client's own `total_cost_usd`, which prices a DeepSeek response with Anthropic prices.

If a lane depends on a cron or `/loop`, the tick check in step 5 is the acceptance test.
A lane whose tick does not fire is moved back immediately (4.4).

### 4.4 Bring a lane back

1. Capture and verify the composer empty as in 4.3.
2. Send the lane's original model, for example `/model opus[1m]`, and verify the footer.
3. Confirm the next tick fires on the original route.

Bringing lanes back is a deliberate decision, not an automatic consequence of pool recovery.

## Part 5 - Drill checklist

Run this once on a quiet evening with the captain informed, while Fable still has headroom, and record the measured timings next to each step.
A drill that has never been run is not a failover.

Preconditions: no lane mid `no-mistakes` run, no incident open, `bin/fm-fable-runway.sh` not RED, Grok above roughly 30 percent of its window.

| # | Step | Measured timing to record |
| --- | --- | --- |
| 1 | Record the baseline: `bin/fm-fable-runway.sh`, `bin/fm-lock.sh status`, watcher beacon age, `quota-axi --provider grok`, fleet tail counts | baseline captured |
| 2 | Warm Grok with `grok --trust` and confirm the nudge tier and the read-only lock refusal | time to a warm, verified session |
| 3 | Arm one Grok supervision cycle and confirm `watcher: started`/`attached` | time to a confirmed cycle |
| 4 | Hand over: finish the Claude turn, `/exit`, verify the lock, start firstmate in Grok, confirm the digest and the drained queue | Claude exit to confirmed lock transfer |
| 5 | Force one real wake and confirm Grok drains, handles, and re-arms | wake to handled and re-armed |
| 6 | Reverse with Part 2 and confirm the Stop auto-arm reclaims supervision, the wake queue is empty, and no `RECORD DIVERGENCE` prints | Grok exit to confirmed Claude supervision |
| 7 | Record the elapsed times and every failure encountered here | total drill time |

Failures worth recording separately: a lock that did not transfer, an arm that never reported a live cycle, a wake that was not drained, a lane tick that did not fire, and any duplicated wake.

## Safety rules

- The check and the monitor are read-only. The supervisor switch and the lane switch are always firstmate actions.
- Never switch a lane mid `no-mistakes` run, and never interrupt a running validation to change models.
- Never relaunch a lane on Pi to change models; that destroys its cron and `/loop` ticks.
- Keep exactly one gateway in the Claude-serving role; a second gateway pointed at the same accounts double-burns the same windows.
- Merge authority is unchanged by any of this: failover changes who supervises, not what may be merged.
