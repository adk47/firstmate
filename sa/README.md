# SA store (SA-01)

The foundation of the Super-agent spine: an append-only event log, a pure fold into ten
tables, and a CLI. The interface contract is
`data/thread2-sa-build/design.md` §0–§6; this package implements it and renames nothing.

```
sa/
  README.md            this file
  lib/sa_paths.py      SA_HOME resolution + canonical JSON helpers
  lib/sa_store.py      event log, fold, projections, schema
  bin/sa-store         the store CLI (the Engine's only write path)
  tests/test_store.py  unittest, stdlib only
  .gitignore           ignores sa/var/
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

## Reproduce

From a clean clone at the repo root:

```sh
sa/bin/sa-store selftest
sa/bin/sa-store tables
python3 -m unittest discover -s sa/tests -v
```

No install step, no environment variables required. `SA_HOME` defaults to `sa/var`, which
is gitignored; point it elsewhere to keep a scratch store.
