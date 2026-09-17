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
- **The model ids are advertised, not negotiated.** `GET /v1/models` advertises `deepseek-v4.1-flash` and `deepseek-v4.1-flash[1m]`.
  A request for either is forwarded upstream under the provider's own model id, which is the only field the gateway rewrites; `cache_control` markers, tool definitions, thinking blocks, and the request body otherwise pass through untouched.
- **Streaming is relayed frame by frame**, and usage is accumulated across `message_start` and `message_delta` because the providers split it.
- **The port is gated by a local token.** Everything except `/healthz` requires the bearer token in `$STATE/fm-deepseek-gateway.token` (mode 0600, created on first use).
  It gates this port, not the providers: it is what stops any other local process from spending the captain's provider cash through an open loopback port.
- **There is no automatic cross-provider failover.** An upstream 429 or 5xx is returned as it arrived, because routing is the picker's decision and silently switching providers would hide both the failure and the cost.
- **`/v1/messages/count_tokens` is a local estimate** of about four characters per token, deliberately not a provider call.

## Setup

```sh
bin/fm-deepseek-gateway.sh start                 # port 8799, the captain's route picker
bin/fm-deepseek-gateway.sh health                # exit 0 only when the route and key resolve
bin/fm-deepseek-gateway.sh env                   # the exports a lane needs, token included
bin/fm-deepseek-gateway.sh logs --lines 20       # one JSON line per request
bin/fm-deepseek-gateway.sh install-launchd       # macOS launch agent, RunAtLoad + KeepAlive
bin/fm-deepseek-gateway.sh plist                 # render that agent without installing it
bin/fm-deepseek-gateway.sh uninstall-launchd
```

`install-launchd` writes `~/Library/LaunchAgents/com.firstmate.deepseek-gateway.plist` from a fixed template, refuses to load a plist that does not match it byte for byte, and carries no secret.
`plist` renders that same definition without installing it, so the recipe can be read and reviewed first.
The agent restarts the gateway across a reboot; `launchd-status` reports whether it is loaded, and while it owns the gateway `stop` refuses and points at `uninstall-launchd` so a manual stop cannot fight the agent's restart.

Point one lane at the gateway and switch its model:

```sh
bin/fm-lane-model-switch.sh <task-id> gateway --gateway     # records the repoint, then switches
bin/fm-lane-model-switch.sh <task-id> 'opus[1m]'            # model switch only, same gateway
```

The switch captures whatever the lane's composer holds, refuses unless the composer verifies empty, sends `/model <spec>` through that lane's own backend submit core, verifies the switch on the rendered screen, records before and after in `state/<id>.meta`, and then kicks the lane back to work.
It also prints the lane's next expected tick, because a model switch can skip the next scheduled tick: the source is `cron=<expr>` lines in that lane's metadata or one expression per line in `data/<id>/crons`, and the script says so explicitly when the home records none.

Claude Code reads its endpoint from the environment at startup, so `--gateway` records the repoint in `state/<id>.meta` (`gateway_url`, `gateway_model`, `gateway_env`) and writes the exact exports to `state/<id>.gateway.env` for whoever launches that lane next.
A lane already pointed at the gateway needs no relaunch; a running session keeps its current endpoint until it is relaunched.

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

1. The heaviest cron-driven polling lane first: several schedules and almost no judgement, which makes it the highest-value and lowest-risk offload.
2. The drift-fix lane second.
3. Then the remaining cron-driven, low-judgement lanes, proving a full day of correct ticks before moving on.
4. Then the judgement-heavy build and analysis lanes, cheapest reasoning first and the most product-sensitive last.
5. The Cloudflare edge-analysis lane stays on Opus 1M: it is the worst fit for a cheap model and the best fit for the bigger window.

Switch one lane at a time, then watch one tick actually fire before the next lane, because the tick is the one thing a switch cannot prove.
A lane that depends on Claude Code crons or `/loop` wakeups is switched in place for exactly that reason: relaunching it on another runtime would silently drop its schedule.

## Limits

- No lane is switched by this change; funding the providers and switching lanes is firstmate's call.
- The gateway is loopback-only and one instance per home; `start` refuses port 8080 and privileged ports.
- `count_tokens` is an estimate, and `cost_usd` in the log is a list-price estimate for operator accounting; the provider's own billing is authoritative.
- Fireworks has a history of rate limiting in this fleet, so treat it as capacity-variable; the gateway reports its errors instead of hiding them.
- The launch agent is macOS-only; on other hosts run `start` under your own supervisor.
- A repointed lane takes its new endpoint at its next launch; a running Claude Code session cannot be repointed in place.

## Verification entry points

- `tests/fm-deepseek-gateway.test.sh` - discovery, per-request routing, key redaction, the unauthenticated refusal, the fail-closed missing-key path, the port refusals, streaming, the launch agent recipe, and the lifecycle verbs.
- `tests/fm-lane-model-switch.test.sh` - the composer refusal paths on fixture screens, the verified switch and its metadata record, the unconfirmed-switch path that must not kick a lane, and the tick report.
- `bin/fm-lint.sh` covers both scripts' ShellCheck surface, and the scripts' own headers own their exact flags and contracts.
