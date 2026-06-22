# Subagent investigation pool — root-cause debug, 2026-05-01

## Context

Run `20260501-135646-ecff37` (500-credit dry-run) was the first load test of the per-profile investigation subagent pool shipped on `feat/credit-batch-investigation-subagents`. Expected: ~117 profiles each investigated by a fresh-context worker, ~50 total minutes wall-clock at pool=10. Actual: 0 successful investigations, 117 fabricated `action_attempted` events, gate held all writes. This document is the forensic post-mortem of why the subagent pool produced zero useful work.

## Findings

### 1. Manifest build worked

`dispatch-investigations.sh` ran successfully and produced:
- `/var/log/openclaw/credit-batch-runs/2026-05-01/20260501-135646-ecff37.manifest.json`
- 117 per-profile prompt files in `/var/log/openclaw/credit-batch-runs/2026-05-01/prompts/20260501-135646-ecff37/`
- Each prompt's HTML-comment ENV header included `INVESTIGATION_OUT_FILE`, `PROFILE_ID`, `SPOTIFY_TRACK_ID`, `ISRC`, etc. (verified by reading one prompt e.g. `02725220-d64c-49cc-b002-4deb2b7094e5.md`)

### 2. Agent only attempted 2 spawns (not 117)

Parent session log `d431c483-d3cc-457b-80b5-b5d61142b826-topic-1777643680.221339.jsonl` shows total `sessions_spawn` calls = 2, both for the same profile `02725220`:

| # | label | model | outcome |
|---|---|---|---|
| 1 | `investigate-02725220-test` | `haiku` | model_not_found → FailoverError (see #3) |
| 2 | `investigate-02725220-test-retry` | `openrouter/openai/gpt-5.5` | spawned, but child hit browser-unavailable (see #4) |

After the retry failed, the agent did NOT fan out to the remaining 116 profiles. It went straight to bulk `action_attempted` for all 117.

### 3. Model alias `haiku` resolves to invalid OpenRouter ID

`openclaw-main.json` defines:
```json
"models": {
  "openrouter/anthropic/claude-haiku-latest": { "alias": "haiku" }
}
```

But `anthropic/claude-haiku-latest` is **not a valid OpenRouter model ID**. The valid ID is `anthropic/claude-haiku-4.5` (released 2025-10-15). Result:

```
[agent/embedded] embedded run agent end: runId=ce2008f4-... isError=true
  model=anthropic/claude-haiku-latest provider=openrouter
  error=HTTP 400: anthropic/claude-haiku-latest is not a valid model ID
```

Found in 5 locations in `openclaw-main.json` (lines 63-64, 123, 133, 274) and mirrored in `openclaw-edge.json`. All 5 should change to `claude-haiku-4.5`.

This is the reason the first spawn failed instantly. Had the agent tried 117 spawns with `model: "haiku"` they would all have failed before doing any work.

### 4. Subagents have no browser-capable node

The retry spawn (model gpt-5.5) ran for ~40 seconds in child session `255db89a-dfe0-4b3c-8ba6-0ea166c07799-topic-1777643680.221339.jsonl`. Three browser tool calls, all errored:

| browser action | target | error |
|---|---|---|
| `open` https://muso.ai/profile/02725220-... | `host` | `timed out. Restart the OpenClaw gateway` |
| `status` | `host` | `timed out. Restart the OpenClaw gateway` |
| `status` | `node: ovh-node-8` | `No connected browser-capable nodes` |

The child then ran `which browser; which openclaw` to diagnose and gave up. No `$INVESTIGATION_OUT_FILE` written.

The parent ran on node-8 with a working browser node (we verified via `journalctl` showing `browser.request 83ms` for parent calls at 13:56:57 and 13:57:37). The browser node is **bound to the parent session** and not inherited by the subagent. Per openclaw subagent docs:

> Sub-agents are background agent runs spawned from an existing agent run. They run in their own session. ... Sub-agents do **not** get session tools by default.

The browser tool itself is in the subagent's allowlist (verified — child did invoke `browser.open`), but the **node binding** isn't transferred. Each child session would need its own browser-capable node connection, which doesn't happen automatically in the current setup.

### 5. After test+retry failed, agent took the bulk-action shortcut

At 14:03:21 (about 5 minutes after the retry's last browser error), the agent emitted 117 `action_attempted` runlog events at the same second, all `action: "flag"`, all with fabricated `evidence_excerpt = "<track> <role>"` strings. It then called `batch-verify-profile.sh` 20 times (batched cr_ids per profile). All 20 invocations exit-5'd at `missing_profile_browse`. Net: 117 rejected_pre_flight rows in `results.jsonl`, 0 admin-api writes, 1 Slack post correctly flagging `DISCREPANCY DETECTED`.

This is the agent's new escape pattern after `UNVERIFIABLE_*` was killed: when subagents fail, panic-finalize via `action_attempted` (not gated) → let `batch-verify-profile.sh` reject everything → claim safe-because-zero-writes.

## Root causes (ordered by impact)

1. **`claude-haiku-latest` is not a valid OpenRouter model ID.** First spawn died instantly. All 5 occurrences need to become `claude-haiku-4.5`.

2. **Subagents cannot reach a browser node.** Child sessions have the `browser` tool but no node connection. The subagent template's required step 1 (anchor load via browser) is impossible. Two viable fixes:

   a. **Recommended:** swap browser for `web_fetch` in the template. We already have `build-search-url.sh` emitting direct entity URLs (Spotify `/track/<id>`, MusicBrainz `/recording/<mbid>` or `/isrc/<code>`). `web_fetch` hits these URLs and returns parsed text; the template's "search for credited_name in proximity to role" step works on returned text. No browser needed.

   b. **Alternative:** configure openclaw to share/inherit the parent's browser node into subagents. Requires openclaw config investigation; not certain it's even supported without depth-2 pattern changes.

3. **Agent does not fan out to all profiles in parallel.** Even if (1) and (2) are fixed, the agent will still serialize spawns one at a time (test+retry pattern shows this). SKILL.md B3 needs an explicit "issue all N agent() calls in a single response" instruction with a worked example.

4. **`action_attempted` is an open channel through the runlog gate.** Closing this is a defensive layer regardless of whether (1)-(3) succeed.

## Recommended fixes (this PR)

| # | Workstream | Action |
|---|---|---|
| 1 | A1+A2 | Extend runlog.sh exit-7 gate to `action_attempted` events (close the bypass) |
| 2 | A3 | Delete B3-fallback inline path from SKILL.md (prevent agent from claiming "fallback" as escape) |
| 3 | B4-a | Replace 5 occurrences of `claude-haiku-latest` with `claude-haiku-4.5` in openclaw-{main,edge,dev}.json |
| 4 | B4-b | Rewrite `templates/investigate-profile.md` step 1-3 to use `web_fetch` against direct entity URLs from `build-search-url.sh`. Remove all `browser` references from the template. |
| 5 | B3 | SKILL.md B3 explicit fan-out instruction: "issue all N agent() calls in this single response, not one-per-turn" |
| 6 | B2 | New `spawn-investigation.sh` wrapper writes `subagent_started` + `subagent_completed_{ok,missing_json,invalid_json}` runlog events for observability. Future runs will show spawn rate vs completion rate at a glance. |
| 7 | C1+C2 | Cap `--max-profiles-per-run` at 50 (default), 200 hard. Document why (window-budget math). |

## Acceptance test (post-fix)

- 20-credit dry-run: ≥4 `subagent_started`, ≥4 `subagent_completed_ok`, 0 `acted_without_investigation`, ≥1 LEGITIMATE verdict if any of the credits has real Tier-1 presence.
- 200-credit dry-run: ≥40 `subagent_completed_ok`, hollow=false, no `DISCREPANCY DETECTED` Slack post.
