# DeepSeek V4.1 Flash for opt-in Claude Code lanes

`bin/fm-deepseek-gateway.sh` (lifecycle) and `bin/fm-deepseek-gateway.py` (the server) run a SECOND local Anthropic-compatible gateway that serves DeepSeek V4.1 Flash to Claude Code lanes that opt in.
`bin/fm-lane-model-switch.sh` switches one live lane's model in place, and optionally repoints that lane at this gateway.

## Why a gateway, measured

Claude Code gates its model choice, and pointing it straight at a provider base URL does not work.
On 2026-09-17 with Claude Code 2.1.274, the same model id and the same prompt failed against both providers directly and worked through this gateway:

```sh
ANTHROPIC_BASE_URL=https://openrouter.ai/api/v1 ANTHROPIC_AUTH_TOKEN=<openrouter key> \
  claude -p --model deepseek-v4.1-flash "Reply with exactly: direct-check"
# There's an issue with the selected model (deepseek-v4.1-flash).
# It may not exist or you may not have access to it. Run --model to pick a different model.

ANTHROPIC_BASE_URL=https://api.fireworks.ai/inference/v1 ANTHROPIC_AUTH_TOKEN=<fireworks key> \
  claude -p --model deepseek-v4.1-flash "Reply with exactly: direct-check"
# same refusal

ANTHROPIC_BASE_URL=http://127.0.0.1:8799 ANTHROPIC_AUTH_TOKEN=<gateway token> \
  claude -p --model deepseek-v4.1-flash "Use the Bash tool to run: cat sample.txt . Then reply with exactly the file content."
# hello world
```

Claude Code fetches the gateway's own model list at session start, which is the mechanism the fleet already uses for its Claude account pool.
This gateway logs that fetch on purpose, so an operator can prove it happened:

```json
{"at": "2026-09-17T20:12:10Z", "outcome": "models", "limit": 1000,
 "models": ["deepseek-v4.1-flash", "deepseek-v4.1-flash[1m]"], "user_agent": "claude-code/2.1.274"}
```

Two facts worth stating plainly, because they differ from the earlier investigation's account:

- In this version the fetched list was not written to a `cache/gateway-models.json` under a scratch config directory; the discovery log line above is the durable proof, not a cache file.
- The same run printed `[claude-code:unrecognized_model]` once per session.
  That warning is about the client's assumed context window, not a refusal: the run completed.
  Append `[1m]` to the model name for the full window, or set `CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000`.

## The two gateways

`127.0.0.1:8080` is the shared Claude account-pool gateway that serves the whole fleet, and it must not be changed or restarted by anything here.
This gateway is a separate process on `127.0.0.1:8799` serving only the lanes explicitly pointed at it, and the lifecycle script refuses port 8080 outright so the two cannot be confused.
One instance per firstmate home owns the port, the pid file, the request log, and the local token.

## How it works

- **Routing is per request.** The upstream provider, model id, base URL, and key are resolved by running the captain's `~/.config/llm-route/pick.py` for every single request, never once at startup, so a lane that crosses DeepSeek's UTC peak window is re-routed without a restart.
  `~/.config/llm-route/README.md` owns that clock: off-peak routes to OpenRouter, DeepSeek's peak routes to Fireworks.
- **The key comes from the picker.** The provider key is read by running the very `api_key_cmd` the picker names, so no secret location is hardcoded here and a captain who moves a key file changes one place.
  No secret is printed, logged, or committed; the request log and every error redact the key.
- **The model ids are advertised, not negotiated.** `GET /v1/models` advertises `deepseek-v4.1-flash` and `deepseek-v4.1-flash[1m]`, and those two exact spellings are the only ones served - anything else, lookalike suffixes included, is a 404.
  A request for either is forwarded upstream under the provider's own model id, which is the only field the gateway rewrites; `cache_control` markers, tool definitions, thinking blocks, and the request body otherwise pass through untouched.
- **Streaming is relayed frame by frame**, and usage is accumulated across `message_start` and `message_delta` because the providers split it.
- **The port is gated by a local token.** Everything except `/healthz` requires the bearer token in `$STATE/fm-deepseek-gateway.token` (mode 0600, created on first use).
  It gates this port, not the providers: it is what stops any other local process from spending the captain's provider cash through an open loopback port.
  `/healthz` is the only path served without the token, and every other path answers 401 without it.
  Unauthenticated it carries liveness, the resolved route, the counters, and a `route_ok` boolean - no request rows and no route-picker text, because a failed row quotes the provider's own error body and the picker's message is an unowned script's stderr.
  Read WITH the token, that same path also carries the picker's own message, which is what `status` prints and `health` does not.
  The per-request rows live in `$STATE/fm-deepseek-gateway.log`, which `logs` reads; it and the gateway's process output are created mode 0600 like the token beside them.
- **There is no automatic cross-provider failover.** An upstream 429 or 5xx is returned as it arrived, because routing is the picker's decision and silently switching providers would hide both the failure and the cost.
- **`/v1/messages/count_tokens` is a local estimate** of about four characters per token, deliberately not a provider call.

## Setup

```sh
bin/fm-deepseek-gateway.sh start                 # port 8799, the captain's route picker
bin/fm-deepseek-gateway.sh health                # exit 0 only when the route and key resolve
bin/fm-deepseek-gateway.sh env                   # the exports a lane needs, token included
bin/fm-deepseek-gateway.sh logs --lines 20       # one JSON line per request
bin/fm-deepseek-gateway.sh stop
```

Supervision belongs to the home, not to this script: run `start` under whatever supervisor the home already uses.
A macOS home that wants the gateway back after a reboot can hand `start --foreground` to launchd - the recipe carries no secret, because the local token stays in the state directory:

```sh
PLIST=~/Library/LaunchAgents/com.firstmate.deepseek-gateway.plist
/usr/libexec/PlistBuddy -c 'Add :Label string com.firstmate.deepseek-gateway' \
  -c "Add :ProgramArguments array" \
  -c "Add :ProgramArguments: string $PWD/bin/fm-deepseek-gateway.sh" \
  -c 'Add :ProgramArguments: string start' -c 'Add :ProgramArguments: string --foreground' \
  -c 'Add :RunAtLoad bool true' -c 'Add :KeepAlive bool true' \
  -c "Add :StandardOutPath string $HOME/.firstmate/state/fm-deepseek-gateway.out" "$PLIST"
launchctl bootout "gui/$(id -u)/com.firstmate.deepseek-gateway" 2>/dev/null
launchctl bootstrap "gui/$(id -u)" "$PLIST"
bin/fm-deepseek-gateway.sh health                # exit 0 once the agent's gateway is serving
```

Point one lane at the gateway and switch its model:

```sh
bin/fm-lane-model-switch.sh <task-id> gateway --gateway     # records the repoint; relaunch the lane to take it
bin/fm-lane-model-switch.sh <task-id> gateway --gateway     # run again once it is relaunched: switches in place
bin/fm-lane-model-switch.sh <task-id> 'opus[1m]'            # model switch only, same gateway
```

**A FIRST `--gateway` repoint only applies to lanes that own no ticks.** Moving a lane onto the gateway takes a relaunch, and a relaunch drops the `/loop` wakeups and `CronCreate` ticks that live in that session's memory - the very thing the in-place switch exists to protect.
So a lane that owns any is refused its first repoint, by name, and stays on the shared account pool until it is intentionally rotated; nothing is written and nothing is typed into it.
A lane that is ALREADY on the gateway is never refused, however many wakeups it has since armed: its `/model` is sent in place, no relaunch is involved, and no schedule can be lost.
Ownership is read from two sources: the home's loop registry (`data/cmux-takeover/expected-loops.json`, or `FM_LANE_SWITCH_LOOP_REGISTRY`), matching the lane's `terminal=` against an entry's `term`, `term_old` or `term_prior_reboot` with a non-empty `expected` list; and this script's own tick convention, `cron=` lines in `state/<id>.meta` or one expression per line in `data/<id>/crons`.
A plain model switch with no `--gateway` is unaffected: a tick-owning lane still changes model in place, which is what that path is for.

List the lanes this home would currently refuse before planning a rollout:

```sh
for m in state/*.meta; do id=${m##*/}; id=${id%.meta}
  bin/fm-lane-model-switch.sh "$id" gateway --gateway --dry-run 2>&1 \
    | grep -q 'stays on the shared account pool' && echo "refused: $id"
done
```

The refusal is checked before the gateway is probed, so this listing works whether or not the gateway is running, and it prints nothing for a lane that is in scope.

Claude Code reads its endpoint from the environment at startup, so a running session cannot be repointed in place, and a session still on the shared account pool cannot accept this gateway's model id at all.
For an in-scope lane, `--gateway` records the repoint FIRST, as soon as the gateway proves healthy, and never depends on the running session: it writes the exact exports to `state/<id>.gateway.env` (mode 0600) for whoever launches that lane next.
It then attempts the in-place `/model` only for a lane that ALREADY had a recorded `state/<id>.gateway.env`, because that file is the only durable evidence its session may already be on the gateway.
For a lane without one - the first command above, and every lane still on the pool - nothing is typed into the lane: the repoint is recorded, the exact relaunch step is printed, and the command exits 0.
That is why the rollout below is "record, relaunch, then switch" for each lane rather than one command.

`state/<id>.gateway.env` is the one record of the repoint; `state/<id>.meta` carries only the `model_switch_gateway=` audit line, and a model switch with no `--gateway` leaves `state/<id>.gateway.env` byte-identical and says so in its report.
`--gateway` takes no value: the gateway is loopback-only, so its port comes from the lifecycle script's own default (`FM_DEEPSEEK_GATEWAY_PORT`, default 8799) and `--gateway=<anything>` is refused rather than probing one endpoint while recording another.

The in-place switch captures whatever the lane's composer holds, refuses unless the composer verifies empty, sends `/model <spec>` through that lane's own backend submit core, verifies the switch on the rendered screen, records before and after in `state/<id>.meta`, and then kicks the lane back to work.
Verification reads only the lines `diff` reports as ADDED between the pre-submit capture and the post-submit one, minus the `/model <spec>` line the script itself submitted - Claude Code echoes that command into its transcript before it decides anything - and it treats Claude Code's own model-rejection renderings, which quote the model id, as an explicit unconfirmed verdict.
A Claude Code pane is bottom-anchored, so new output is inserted above the composer and a full pane scrolls its top away; diff aligns the two captures, which is what keeps content carried over from before the submit - including this script's own earlier kick text, which names the model - out of the evidence.
A capture with no added line at all confirms nothing: a switch that does not confirm is not recorded and does not kick the lane.
Because the rule aligns rather than compares by index, a retry after a slow redraw still verifies even when the confirmation line repeats one already on screen.

It also prints the cron expressions the home records for that lane - `cron=<expr>` lines in its metadata and one expression per line in `data/<id>/crons` - verbatim and against the time it read them, and says so explicitly when the home records none.
No fire time is computed: a model switch can skip the next scheduled tick, and watching the real fire is the only thing that proves the schedule survived.

## Proof sequence

Re-runnable against a gateway started on a scratch state directory, so nothing in a live home is touched.
Run each command from a scratch working directory and compare against the measured results below.

```sh
WORK=$(mktemp -d); mkdir -p "$WORK/home/state" "$WORK/cfg" "$WORK/lane"
FM_HOME="$WORK/home" FM_STATE_OVERRIDE="$WORK/home/state" \
  bin/fm-deepseek-gateway.sh start --port 8799 --pick ~/.config/llm-route/pick.py
cd "$WORK/lane"; printf 'hello world\n' > sample.txt; printf 'alpha\n' > a.txt; printf 'beta\n' > b.txt
export ANTHROPIC_BASE_URL=http://127.0.0.1:8799
export ANTHROPIC_AUTH_TOKEN=$(cat "$WORK/home/state/fm-deepseek-gateway.token")
export CLAUDE_CONFIG_DIR="$WORK/cfg"

# 1. tool call
claude -p --dangerously-skip-permissions --model deepseek-v4.1-flash \
  "Use the Bash tool to run: cat sample.txt . Then reply with exactly the file content."

# 2. multi-turn agentic work: read two files, write a third
claude -p --dangerously-skip-permissions --model 'deepseek-v4.1-flash[1m]' \
  "Read a.txt and b.txt with the Bash tool, then write c.txt containing their contents joined by a newline in that order, then reply with exactly the contents of c.txt."
cat c.txt

# 3. discovery and per-request accounting
grep '"outcome": "models"' "$WORK/home/state/fm-deepseek-gateway.log"
tail -3 "$WORK/home/state/fm-deepseek-gateway.log"
```

Measured on 2026-09-17, Claude Code 2.1.274, off-peak so routed to OpenRouter:

| Step | Result |
| --- | --- |
| 1. tool call | `hello world`, one request, 1.6 s |
| 2. multi-turn | `c.txt` contained `alpha` then `beta`, four requests |
| 3. discovery | `{"outcome": "models", "user_agent": "claude-code/2.1.274"}` |
| 3. prompt cache | first request of a session `input_tokens 17297, cache_read 0`; the next `input_tokens 361, cache_read_input_tokens 17536` |
| 3. cost | that cached call cost $0.0003 against $0.0026 for the uncached one |

### The peak route, against the real Fireworks endpoint

The table above was measured off peak, so it only proves OpenRouter.
The peak route carries every opted-in lane for seven hours each weekday, so it was run separately on 2026-09-17 with the picker pinned to its own `peak` route and the real Fireworks key - the same clock the picker uses on its own selects that route Mon-Fri 01:00-04:00 and 06:00-10:00 UTC.

| Step | Result |
| --- | --- |
| 1. tool call | `hello world` |
| 2. multi-turn | `c.txt` contained `alpha` then `beta` |
| routing | all 9 requests `upstream_status 200`, `provider fireworks-us`, `slot peak`, `upstream_model accounts/fireworks/models/deepseek-v4p1-flash` |
| prompt cache | cache reads of 17676, 17698, 17840, 18170 and 18594 tokens against an approximately 18k-token prompt |
| cost | $0.011 for the whole run |

One recorded response from that run: id `msg_de04d842fed054f511fc125d`, model `accounts/fireworks/models/deepseek-v4p1-flash`, HTTP 200, usage `input_tokens 36` and `output_tokens 16`, cost $0.000018.

Claude Code's request body - `cache_control` markers on the tool block included - reaches Fireworks unchanged and is accepted, which is what the off-peak run could not show.
`tests/fm-deepseek-gateway.test.sh` pins the other half in CI: its fake upstream serves each provider's own path shape and refuses anything else, so the peak route's URL is proven by test rather than by the route the fixture happened to start on.

Prompt caching is the whole game: a lane with a stable prefix pays about a tenth of the input rate for it, and a lane that rewrites its own system prompt every turn loses that discount.
The gateway only passes the markers through; it is Claude Code's own `cache_control` blocks that make the providers serve a prefix from cache.
The whole proof above cost about three cents at off-peak list prices.

## Cost per million tokens

| Window (UTC, Mon-Fri) | Provider | Model id | $/1M in | $/1M out |
| --- | --- | --- | ---: | ---: |
| off-peak: every hour outside those two windows, and all of Saturday and Sunday | OpenRouter, pinned to a cheap host | `deepseek/deepseek-v4.1-flash` | 0.15 | 0.60 |
| peak: 01:00-04:00 and 06:00-10:00 | Fireworks US | `accounts/fireworks/models/deepseek-v4p1-flash` | 0.22 | 0.66 |
| never used, for comparison | DeepSeek official at its peak | - | 0.30 | 1.20 |
| avoided, but reachable | OpenRouter's default routing, which lands on a $0.30/$1.20 host on most of its endpoints | - | 0.30 | 1.20 |

Cache reads bill at roughly a tenth of the input rate, which is why the measured per-call cost above fell by an order of magnitude once a prefix was warm.
Projected onto the Opus lanes' own measured 24-hour volume (5.07B cache-read tokens and 10.1M output tokens), the earlier investigation put the offload at roughly $100-150 per day with that cache behaviour, against about $789 per day with no cache discount at OpenRouter's cheap rate and about $1,578 per day unpinned.

One caveat that belongs to the captain's own router, not to this gateway: `~/.config/llm-route/pick.py` currently relies on OpenRouter's default host choice, and the investigation measured that default landing on a $0.30/$1.20 host.
Pinning a cheap host in the picker's off-peak route, or sending off-peak to Fireworks as well, is what makes the $0.15 figure real.

## Rollout order

The earlier investigation's order, unchanged, and this change performs none of it: no lane is switched here.
It is written as lane classes rather than lane names, because a home's roster is private and the classes are what decide the risk.

The rollout is scoped by tick ownership, not by lane name, because the relaunch a repoint needs is exactly what a tick-owning lane cannot survive.

1. **Tick-owning lanes are out of scope for a first repoint and the tool refuses them.** Run the listing command in Setup to see which ones this home currently refuses. They stay on the shared account pool until someone decides to rotate them deliberately - a decision that costs one relaunch plus re-arming every `/loop` and `CronCreate` by hand, and is not part of this rollout.
2. **Lanes that own no ticks are the rollout.** Each is three steps: record its repoint, relaunch it with the recorded endpoint, then run the same `--gateway` command again to switch it in place.
3. Do one lane at a time. Cheapest-judgement lanes first, the most product-sensitive last, and the edge-analysis work that wants the bigger window stays on Opus 1M because it is the worst fit for a cheap model.
4. After each lane, confirm it is actually serving through the gateway - `bin/fm-deepseek-gateway.sh logs --lines 5` shows its requests with the provider and slot they took - before starting the next.

Once a lane is on the gateway, every later model change is in place and costs no relaunch at all.

## Limits

- No lane is switched by this change; funding the providers and switching lanes is firstmate's call.
- The gateway is loopback-only and one instance per home; `start` refuses port 8080 and privileged ports.
- `count_tokens` is an estimate, and `cost_usd` in the log is a list-price estimate for operator accounting; the provider's own billing is authoritative.
- Fireworks has a history of rate limiting in this fleet, so treat it as capacity-variable; the gateway reports its errors instead of hiding them.
- This script does not supervise the gateway; `start` runs it and the home's own supervisor keeps it alive across a reboot.
- A repointed lane takes its new endpoint at its next launch; a running Claude Code session cannot be repointed in place, so the first `--gateway` run on an in-scope lane records the repoint and types nothing into the lane.
- A lane that owns `/loop` wakeups or recorded crons is refused a repoint outright, because the relaunch it would need is what drops those schedules. Moving such a lane is a deliberate decision made outside this tool.
- Tick ownership is read from what the home records. A lane whose schedule is armed but recorded nowhere reads as tick-free, so keep the loop registry and `cron=` lines current before a rollout.
- The switch prints the lane's recorded cron expressions and the time it read them; it computes no fire time, so the operator watches the real tick.

## Verification entry points

- `tests/fm-deepseek-gateway.test.sh` - discovery, per-request routing against each provider's own path shape, key redaction, the unauthenticated refusal, request rows living only in the log that `logs` reads, the fail-closed missing-key path, the port refusals, a start onto a port another instance holds, an upstream that dies mid-relay being recorded, streaming, the 0600 process output, and the lifecycle verbs.
- `tests/fm-lane-model-switch.test.sh` - the composer refusal paths on fixture screens, the verified switch and its metadata record, the echo-only screen and the client's own model rejection that must not count as confirmations, the retry whose confirmation repeats an existing line and must still be recorded, the unconfirmed-switch path that must not kick a lane, a real gateway repoint recorded without typing into a pool lane and then taken in place once recorded, the tick-owning lanes that are refused a first repoint while an already-repointed lane still switches in place, and the tick report.
- `bin/fm-lint.sh` covers both scripts' ShellCheck surface, and the scripts' own headers own their exact flags and contracts.
