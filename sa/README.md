# SA store, dispatch gate, and kill switch (SA-01, SA-03)

The foundation of the Super-agent spine: an append-only event log, a pure fold into ten
tables, and a CLI (SA-01), plus the DoD gate, dispatch, Mandate, and kill switch (SA-03).
The interface contract is `data/thread2-sa-build/design.md` §0–§10; this package
implements it and renames nothing.

```
sa/
  README.md              this file
  lib/sa_paths.py        SA_HOME resolution + canonical JSON helpers
  lib/sa_store.py        event log, fold, projections, schema
  bin/sa-store           the store CLI (the Engine's only write path)
  bin/sa-dispatch        the DoD gate, dispatch, and Mandate (SA-03)
  bin/sa-kill            the kill switch: stops only registered SA workers
  tests/test_store.py    unittest, stdlib only
  tests/test_dispatch.sh the gate, dispatch, Mandate, and kill-switch proof
  .gitignore             ignores sa/var/
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
- `payload` — object; shape is per event type. The append path rejects a payload the fold
  cannot represent (a non-list `scope_paths`/`rules_in_force`, a non-numeric `tokens`/`calls`,
  a non-string table key such as `thread`, `sub`, `event_id`, `id`, or `tier`) rather than
  logging it, because the log is append-only.

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

`query --where k=v` compares the right-hand side as JSON when it parses (`false`, `true`,
`null`, numbers) and as a plain string otherwise, so `--where revoked=false` selects the
false-valued rows and `--where owner=null` selects the null ones. `query --table events`
returns rows in numeric `seq` order; every other table is key-ordered.

`selftest` builds a fresh temp `SA_HOME`, appends a deterministic fixture covering every
event type, folds the log twice, asserts `sha256(A) == sha256(B)`, asserts all ten tables
are present, and prints both hashes plus `PASS` (exit 0) or the diff (exit 1).

## Dispatch gate and Mandate (SA-03)

```
sa-dispatch intake --ticket T [--dry-run] [--mode M] [--yolo on|off] [--harness H]
                          [--scope PATH]... [--rule RULE]... [--ttl-hours N]
                                                       -> gate result; on pass, dispatch
sa-dispatch mandate --ticket T                         -> canonical JSON mandate
sa-dispatch check-scope --ticket T --path P            -> exit 0 allowed / exit 4 not allowed
```

`intake` refuses a ticket whose `acceptance` has no non-empty `command` and no `signal`
matching `^(exit|file|grep|http):`, and a ticket that names no `requester`. A refusal
appends `ticket.refused` carrying the missing question and exits 3. A ticket that already
holds a live mandate is refused rather than dispatched twice; a ticket whose mandate was
revoked (a failed attempt) or has expired can be retried, because the previous attempt's
brief is moved aside before a fresh one is scaffolded.

On pass, one run scaffolds one brief with `bin/fm-brief.sh`, creates one git worktree and
one worker with `bin/fm-spawn.sh --backend tmux`, and appends `mandate.issued` carrying
`requester`, `scope_paths`, `rules_in_force`, and `expires_at`. Both helpers run with
`FM_HOME=$SA_HOME`, so nothing lands in firstmate's home. Workers live in their own tmux
session (`SA_TMUX_SESSION`, default `sa-workers`), never in firstmate's. `--dry-run`
performs the gate and prints the plan without creating anything.

`check-scope` refuses a revoked or expired mandate as well as a path outside the scope.

## Kill switch (SA-03)

```
sa-kill [--dry-run] [--registry PATH]                  -> stop every registered SA worker
```

`sa-kill` reads `$SA_HOME/workers.json` (the rows `sa-dispatch` writes) and stops each
registered tmux endpoint by exact name. It refuses any endpoint naming `firstmate`,
`fm-`, or `ak47-anchor`, and any `session:window` endpoint outside the SA worker session,
so it can never reach firstmate's own windows. An endpoint that is already gone counts as
stopped, so the switch is idempotent. Exit codes: 0 all stopped, 2 usage/registry error,
6 at least one worker could not be stopped or was refused.

## Reproduce

From a clean clone at the repo root:

```sh
sa/bin/sa-store selftest
sa/bin/sa-store tables
python3 -m unittest discover -s sa/tests -v
sa/tests/test_dispatch.sh
```

No install step, no environment variables required. `SA_HOME` defaults to `sa/var`, which
is gitignored; point it elsewhere to keep a scratch store.
