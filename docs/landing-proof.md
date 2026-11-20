# Landing proof

A worker's `done:` line is a claim, not proof.
Work has landed only when an independent read of the system of record shows it: the merged and deployed commit, the production count, the live flag value, the served bytes, the sent message id.
This is the authoritative contract for how a claim carries the command that proves it, and for what firstmate does with that command.

The contract has three owners:

- `bin/fm-dod-lib.sh` renders it into every generated Definition of done (`fm_landing_proof_block`), for every delivery mode and for scouts, so `bin/fm-brief.sh` and `bin/fm-promote.sh` hand workers the same text.
- `bin/fm-classify-lib.sh` owns the field grammar (`status_line_landing_fields_core`), with no model involved.
- `bin/fm-landing-claim.sh` owns the claims-file row and its append; its header owns the exact format, defaults, and exit codes.

## Why

A worker reporting "done" has always been taken at its word.
The failures that motivated this contract all had the same shape: the worker wrote `done`, the system of record said otherwise, and nothing caught it.
Assets never reached the bucket, a sample was rendered from old code, a drain wrote zero approvals to the core store, and deploys failed after the PR merged.
Each one was visible in seconds to a single read of the right system, so the read is now part of the claim.

## The claim shape

```
done: <claim> kind: <kind> proof: <command> expect: <extended regex> [told: <command> told-expect: <extended regex>] [lesson: <fact>]
```

- `proof:` is one shell command whose stdout shows the work landed, and `expect:` is the extended regular expression that stdout must match.
  Both are required on every `done:` line.
- `told:` and `told-expect:` are the same pair for proof that the customer was told; customer-facing work carries them, and their presence is what marks a claim customer-facing.
- `kind:` names what is claimed; when absent it is inferred as `pr` for a claim naming a pull-request URL, `branch` for "ready in branch", and `other` otherwise.
- `lesson:` remains the house-wiki trailing clause and is never part of a proof value.

Each label is a whole word with whitespace before it and after it, clauses may appear in any order after the claim text, and each value runs to the next label.
A value therefore cannot contain a tab, a newline, or one of the labels as a separate word.
A line with a proof clause but no expect clause, the reverse, half a told pair, a repeated or empty clause, or an unknown kind is malformed and is not recorded.

A proof command runs from an unknown directory, in a fresh shell, with a few seconds of budget, so it uses absolute paths, never relies on variables from the worker's own session, and only reads.
It is written to pass once the work has truly landed, not necessarily at the moment the worker writes it; a PR proof normally fails until the merge and deploy finish, and that is the point.

## What landed means, by kind

| Kind | Landed means | Typical proof reads |
|------|--------------|---------------------|
| `pr` | merged, the deploy completed, and the running version contains the merge commit | the service's running version compared with `gh pr view --json mergeCommit`; merged state alone only for a project with no deploy step |
| `data` | the production count or metric moved in the expected direction | the production store itself |
| `flag` | the live flag or config value, read back through the application's own path | the application's read path, never the edited file |
| `asset` | the deployed build serves the new copy or bytes | `curl` of the public URL |
| `notify` | the send ledger holds a real provider message id | the ledger entry |
| `branch` | the commit exists, or for local-only delivery has reached the default branch | the repository's shared object store through `git --git-dir=<common dir>`, which survives cleanup of the worker's local copy |
| `report` | the scout report exists with content | `test -s <report path>` |

## What firstmate does with a claim

On a `done:` notification firstmate passes the worker's line to `bin/fm-landing-claim.sh append <task> <line>` (or `from-status <task>`, which takes the newest `done:` line from the task's status log).

- A well-formed claim becomes one row in the claims file the landing checker reads.
  A replayed claim is recognized and not appended twice.
- A `done:` line with no `proof:` clause is reported as unproven, and firstmate tells the worker the task is back in progress until it appends a `done:` line that carries one.
- A malformed claim is treated the same way, with the parse error as the reason.

The landing checker is a private, home-local check that runs each row's proof command on a schedule, compares stdout with the row's regex, and needs no model.
It reports a claim whose proof still does not match 30 minutes after it was made as claimed but not landed, reports customer-facing work that landed with no matching told proof as landed but not told, and reports a recent `done:` that has no claims row at all.
Its schedule, paging, and exclusions are that home's private configuration, not part of this contract.
