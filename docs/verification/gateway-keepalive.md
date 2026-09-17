# Inference-gateway keep-alive verification

Active empirical facts behind [`../gateway-keepalive.md`](../gateway-keepalive.md).
Refresh this record after a Claude Code upgrade that changes hook events or the `StopFailure` payload.

## Which hook a 503 turn end fires

Verified 2026-09-09 on Claude Code 2.1.266, macOS 25.4.0.

A local stub answering every request with HTTP 503 was put in front of the session through project-scoped `env.ANTHROPIC_BASE_URL`, with all four Claude lifecycle events registered to a payload-logging hook.
Claude Code retried internally for about four minutes, then gave up and ended the turn.

Events fired, in order: `UserPromptSubmit`, `StopFailure`, `SessionEnd`.
`Stop` did not fire.

The `StopFailure` payload:

```json
{
  "session_id": "33b7d5cb-904c-40f1-a835-ec72350acca5",
  "transcript_path": "…/33b7d5cb-904c-40f1-a835-ec72350acca5.jsonl",
  "cwd": "…",
  "prompt_id": "92216084-6515-47b9-8792-2308bc7c9a1e",
  "effort": {"level": "high"},
  "hook_event_name": "StopFailure",
  "error": "server_error",
  "last_assistant_message": "API Error: 503 All accounts are temporarily unavailable. This is a server-side issue, usually temporary — try again in a moment. If it persists, check your inference gateway (127.0.0.1:18503)."
}
```

The same conclusion is visible in live fleet state independent of the stub: a lane stalled on the pooled gateway the same day recorded `state=idle source=claude-hook event=stop-failure`, which is the busy contract's `StopFailure` writer and not its `Stop` writer.

This is why the keep-alive cannot be a `Stop` hook: the event a gateway failure raises is `StopFailure`.

## Why a StopFailure hook cannot block or continue the turn

`StopFailure` is executed outside the REPL loop.
In 2.1.266 the executor is:

```js
async function F7e(e,n,r=pf){                              // executeStopFailureHooks
  …
  await nA({ …, hookInput:{ …, hook_event_name:"StopFailure", error:d, … } });
}
```

`nA` is `executeHooksOutsideREPL`; it returns per-hook results and `F7e` discards them.
`Stop` is executed by `qJ` (`executeStopHooks`), an async generator whose results are yielded back into the turn loop, which is what lets exit 2 plus stderr force a continuation there.
`StopFailure` is also a member of the event set the binary treats as non-blockable, alongside `Notification`, `SessionStart`, `SessionEnd`, and `PostToolUseFailure`.

A `StopFailure` hook therefore has no continuation channel at all, whatever it exits with.
This is the reason the keep-alive is built as detect-then-re-ring from outside the session rather than as a blocking hook: the rendered pane is the single detector, and the watcher delivers the continue instruction.
An earlier revision also registered a `StopFailure` hook purely to open the stall record a few seconds before the next pane poll; it was removed because both re-ringing actors classify the pane anyway, the first attempt waits out a backoff regardless, and a record opened by anything other than the pane could hold the ladder open against a pane that had already recovered.

## The typed error enum

Recorded for the next reader who considers a typed detector; nothing in the keep-alive reads this field, because no actor outside the session ever sees the payload.
`StopFailure`'s `error` field is a closed enum in 2.1.266:

```
authentication_failed, oauth_org_not_allowed, account_on_hold, billing_error,
rate_limit, overloaded, invalid_request, model_not_found, server_error,
unknown, max_output_tokens
```

`overloaded` and `server_error` are the transient gateway class.
`authentication_failed`, `oauth_org_not_allowed`, `account_on_hold`, `billing_error`, `rate_limit`, `invalid_request`, `model_not_found`, and `max_output_tokens` are the kinds that must never be retried, and the text deny list covers their rendered wording.

## Error-text census

Taken 2026-09-09 across 201 transcripts in this fleet's `~/.claude/projects`, counting assistant entries carrying `isApiErrorMessage: true`.
These are the strings the pane classifier is written against; the counts are what makes the deny list load-bearing rather than theoretical.
Only the rendered `API Error: <5xx>` shape is a positive match, and only within the bounded tail window above the prompt; the gateway's own sentences and the bare word `Overloaded` are not matched on their own, so a crewmate printing this repository's sources cannot classify as stalled.

| Count | Text (truncated) | Class |
|---|---|---|
| 2427 | `API Error: 503 Service temporarily unavailable. …` | transient |
| 1692 | `API Error: 503 All accounts are temporarily unavailable. …` | transient |
| 990 | `Prompt is too long` | permanent |
| 212 | `Autocompact is thrashing: …` | permanent |
| 141 | `API Error: Unable to connect to API (ENOTFOUND)` | outage, not retried |
| 83 | `API Error: 529 Overloaded. …` | transient |
| 48 | `Prompt is too long · automatic compaction failed: API Error: 503 …` | permanent, and carries a 503 |
| 37 | `API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited` | permanent |
| 36 | `API Error: 500 Internal server error. …` | transient |
| 30 | `You've hit your limit · resets …` | permanent |
| 17 | `API Error: Unable to connect to API (ConnectionRefused)` | outage, not retried |
| 15 | `Login expired · Please run /login` | permanent |
| 12 | `API Error: 400 messages.…` | permanent |

The 48-occurrence row is the reason the deny list is checked before the transient patterns and beats the typed kind as well: it is a context failure wearing a gateway failure's code, and re-ringing it would spend the whole budget with no chance of progress.

The rendered text uses an em dash (`—`), not a hyphen.
`tests/fm-gateway-keepalive.test.sh` quotes these strings verbatim, so a classifier rewritten against a hyphen fails there instead of silently never matching in production.
