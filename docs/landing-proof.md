# Landing proof

A worker's `done:` is a claim, not proof.
A ship task has landed only when its acceptance probe - a script Firstmate writes at intake that reads the live consumer surface - exits 0 when something other than the worker runs it.
This page is the operator view of that loop; each piece's script header owns its exact behavior.

## The pieces

- **The probe.** `bin/fm-brief.sh` and `bin/fm-promote.sh` refuse a ship task without `--probe <file>`.
  `bin/fm-dod-lib.sh` installs it at `state/acceptance/<task>.sh` (mode 0700) with its sha256 in `state/acceptance/<task>.trust`, refuses a probe that reads a project clone or task worktree, and renders the Definition of done that tells the worker done means the probe passing and forbids editing it.
- **The row.** `bin/fm-change-watch.sh claim` registers the claim as a durable change-watch row (`kind: claim`, `pr_url` null until a PR exists) carrying `acceptance {probe_path, sha256, last_exit, last_epoch}`, with readings at the claim and at +15m, +1h, and +6h.
  The row reads `proven` on the first exit 0 and `absent` if the probe still fails at +6h; `absent` is a terminal failure distinct from `regressed`.
- **The runner.** `bin/fm-landing-police.sh tick` registers a claim when a ship task's newest status line is `done:`, and takes each due reading with `bin/fm-change-watch.sh acceptance`, which runs the bound probe itself from `/` with a clean environment and a timeout and accepts no exit code from its caller.
  The probe's hash is re-checked first, and an edited probe records exit 125 without running.
  It reports a `done:` with no probe, an edited probe, a claim past its one-hour deadline (at most once an hour), and a claim that read absent; it prints nothing otherwise.
  `bin/fm-landing-police.sh arm` writes and registers `state/landing-police.check.sh` through `bin/fm-check-register.sh`, so the watcher runs it on every poll.
- **The gate.** `fm_landed_proven` in `bin/fm-landed-lib.sh` reads the claim row, and `bin/fm-teardown.sh` refuses cleanup of a ship task that has a probe until its row is `proven`.
  A task has a probe when its script, its trust binding, or its claim row exists, so deleting the script cannot bypass the gate.
  A task briefed before probes existed has none of those and is not gated.

## Writing a probe

A probe reads what the customer reads, never the repo:

- served bytes or a page: `curl -fsS <public url> | grep -q '<new text>'`
- a bucket object: its size or hash through the bucket's public URL or API
- a deploy: the running revision's image compared with the merge commit's build, plus ready pods above zero
- data: a production row count or metric moved in the expected direction

It must run unchanged from `/` in a few seconds, read only, and exit 0 only once the change is live.
A probe for work not yet done fails now; that is the point.

## Merged-change watches

The same row store also holds merge watches.
A merge whose deploy run carrying the merge commit failed reads `absent`, not `regressed`, because the change never reached production.
A merge whose diff touches nothing deployable records `deploy_expected=no` and keeps no deploy-workflow target, so a failed or missing run says nothing about it.
A merge with no measurable surface at all is the one whose row ends `not-applicable`.
`.agents/skills/change-watch/SKILL.md` owns how firstmate handles each wake.
