# SA package: store (SA-01) and router (SA-02)

The foundation of the Super-agent spine: an append-only event log, a pure fold into ten tables, and two CLIs.
The store is the Engine's only write path; the router is the only surface a Router session can reach.
The interface contract is `data/thread2-sa-build/design.md` §0–§6; this package implements it and renames nothing.

```
sa/
  README.md                this file
  lib/sa_paths.py          SA_HOME resolution + canonical JSON helpers
  lib/sa_store.py          event log, fold, projections, schema
  bin/sa-store             the store CLI (the Engine's only write path)
  bin/sa-cli               the router CLI (five verbs, no shell, no file access)
  extensions/sa-router.ts  the Router's five-tool Pi extension
  tests/test_store.py      unittest, stdlib only
  .gitignore               ignores sa/var/
```

## Non-negotiables

1. **The Engine is the sole writer.** `sa-store append` is the only code path that opens
   `events.jsonl` for writing. Every other component appends by calling it.
2. **`SA_HOME` is the only writable root.** Nothing in `sa/` writes into firstmate's home.
3. **Python 3 stdlib only.** No pip installs, no new dependencies.
4. **Move files, never delete.**

## `SA_HOME` and canonical JSON

- `SA_HOME` = `$SA_HOME` if set, else `<repo>/sa/var` (gitignored). Tests always use a temp
  `SA_HOME`.
- Canonical JSON is `json.dumps(obj, sort_keys=True, separators=(",", ":"),
  ensure_ascii=False)`. Every persisted byte and every printed state uses it, which is what
  makes "byte-identical replay" a real test rather than a vibe.
- The log is `$SA_HOME/events.jsonl`: one canonical JSON object per line, LF terminated.

## Event envelope

```json
{"actor":"router","at":"2026-11-05T02:10:00Z","id":"ev-0000000000000001","payload":{},"seq":1,"ticket":null,"type":"ticket.created"}
```

- `seq` — monotonic integer assigned by the Engine at append, starting at 1.
- `id` — `ev-` + zero-padded 16-digit `seq`. Deterministic, so replay is byte-stable.
- `at` — ISO-8601 UTC seconds, caller-supplied or defaulted to now. Offsets are normalized
  to `Z`; a naive or unparseable timestamp is rejected rather than logged.
- `actor` — one of `router`, `engine`, `code`, `worker`, `human`.
- `ticket` — a ticket id or `null`.
- `payload` — object; shape is per event type.

## Ten tables

All ten exist from day 1, including `usage` and `claims`, which are the scorecard's source.

| table | key | fields |
|---|---|---|
| `events` | `seq` | the envelope itself |
| `tickets` | `id` | `id, title, body, requester, state, class, acceptance, owner, created_at, updated_at` |
| `mandates` | `ticket` | `ticket, requester, scope_paths[], rules_in_force[], issued_at, expires_at, revoked` |
| `threads` | `id` | `id, ticket, opened_at, messages[]` |
| `subs` | `id` | `id, ticket, parent, role, state, created_at` |
| `assignments` | `ticket` | `ticket, owner, reason, assigned_at` |
| `outbox` | `event_id` | `event_id, ticket, owner, state, attempts, enqueued_at, delivered_at, last_error` |
| `rulings` | `id` | `id, ticket, ruling, rationale, actor, at` |
| `usage` | `ticket` | `ticket, by_tier{tier:{tokens,calls}}, total_tokens` |
| `claims` | `id` | `id, ticket, claim, evidence_command, at` |

Projections are a pure fold of the log: `sa-store state` prints the whole snapshot,
`sa-store state --table <name>` prints one table. Table keys are JSON object keys, so
`events` is keyed by the string form of `seq`.

## Event types

`ticket.created`, `ticket.classified`, `ticket.assigned`, `ticket.refused`,
`ticket.dispatched`, `mandate.issued`, `mandate.revoked`, `thread.opened`,
`thread.message`, `sub.spawned`, `assignment.created`, `outbox.enqueued`,
`outbox.delivered`, `outbox.failed`, `ruling.recorded`, `usage.recorded`,
`claim.recorded`.

Unknown event types are **recorded in `events` and ignored by projections** — never an
error. That keeps the log forward-compatible.

Fold details worth knowing when reading state:

- `ticket.created` may omit the envelope `ticket`; the fold then names the ticket
  `T-` + the event's `seq`. The Engine owns `seq`, so it owns ticket ids: a creator that
  cannot know the seq yet never has to predict one, and two concurrent creators cannot
  collide onto one id.
- `ticket.assigned` updates the ticket's `owner`/`state`; `assignment.created` writes the
  `assignments` row. They are separate events with separate tables.
- `usage.recorded` accumulates into `by_tier[tier]` and `total_tokens`. A usage event with
  no ticket is keyed `unassigned` rather than dropped.
- `rulings` and `claims` rows get a deterministic id derived from the event `seq`
  (`rul-…`/`clm-…`) unless the payload supplies `id`, so replay stays byte-stable.
- `outbox.delivered` increments `attempts` and takes `delivered_at` from the receipt's `at`
  when present; `outbox.failed` takes `attempts` from the payload's `attempt`.

## CLI

```
sa-store append --type T --actor A [--ticket X] [--at ISO] [--payload JSON]   -> prints event id
sa-store state [--table NAME]                                                 -> canonical JSON
sa-store tables                                                               -> one name per line
sa-store query --table NAME [--where k=v]...                                  -> canonical JSON array
sa-store selftest                                                             -> PASS/FAIL + hashes
sa-store log                                                                  -> raw events.jsonl
```

`selftest` builds a fresh temp `SA_HOME`, appends a deterministic fixture covering every
event type, folds the log twice, asserts `sha256(A) == sha256(B)`, asserts all ten tables
are present, and prints both hashes plus `PASS` (exit 0) or the diff (exit 1).

## Router surface (SA-02)

`sa/bin/sa-cli` is the only thing a Router session can reach, and it has exactly five verbs:

```
sa-cli ticket   --title T --body B --requester R [--acceptance JSON]  -> ticket id
sa-cli assign   --ticket T --owner O --reason R
sa-cli reply    --ticket T --text X
sa-cli rule     --ticket T --ruling X --rationale R
sa-cli escalate --ticket T --to X --why Y
```

There is no bash, sh, exec, read, cat, edit, or write verb: a verb that ran arbitrary input or touched a file directly would break the premise.
Every verb appends through `sa-store append`, so the store stays the sole writer.
Exit codes are `0` success, `2` unknown command (with the verb list on stderr), and `3` the store is missing or refused the append.

`sa/extensions/sa-router.ts` registers exactly five tools - `sa_ticket`, `sa_assign`, `sa_reply`, `sa_rule`, `sa_escalate` - and no commands and no event hooks.
Each tool is a thin wrapper over `python3 sa/bin/sa-cli <verb> ...` run through `pi.exec` with an argv array, so no shell is involved.
A Router session launched with `--no-builtin-tools --no-mcp --tools sa_ticket,sa_assign,sa_reply,sa_rule,sa_escalate` therefore has those five tools and cannot reach a shell, a file read, or an edit.

Two router behaviours worth knowing:

- `ticket` sends no envelope ticket and prints the id the Engine assigned, read back from the appended event's `seq` (`T-` plus the zero-padded seq).
  Predicting the id before the append would race a concurrent creator and collide two tickets onto one id.
- `escalate` records `ticket.escalated`, which is not one of the store's event types, so it lands in `events` and folds into no projection.
  Query it with `sa-store query --table events --where type=ticket.escalated`.

## Reproduce

From a clean clone at the repo root:

```sh
sa/bin/sa-store selftest
sa/bin/sa-store tables
python3 -m unittest discover -s sa/tests -v
tests/sa-router.test.sh
```

No install step, no environment variables required. `SA_HOME` defaults to `sa/var`, which
is gitignored; point it elsewhere to keep a scratch store.
