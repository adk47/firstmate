# Profile-merge queue: the schedules (node-8)

The queue's *code* belongs to core-backend (`scripts/ops/merge-queue/`). The *clock* that
runs it lives on node-8, so hydra owns it — and until now that clock existed only in
`/etc/cron.d`, which is why a hand edit could quietly break it.

## What is here

| file | what |
|---|---|
| `install-cron.sh` | the ONE writer of `/etc/cron.d/merge-queue-census` and `/etc/cron.d/merge-queue-variant-queue`; called by `scripts/install-aux-units.sh` |
| `run-census.sh` | the census pass (`*/30`): refresh `clickup.json` + `plan.json`, message nobody |
| `run-variant-queue.sh` | the reply pass (`10:17` daily): plan → variant plan → the APPROVED copy (`q1-copy-1103`, Fable 2026-11-03). **An unflagged run SENDS** (`--apply`); `--dry-run` is the only preview |
| `chain-preflight.sh` | compares the deployed chain copies (`/root/q1`) with `chain-manifest.sha256` |
| `chain-manifest.sha256` | the pinned bytes + the core-backend commit they came from |

## Why the pin

`/root/q1` is populated by hand, so the bytes that actually run are invisible to review. A
stale `send_variant_copy.py` sends copy nobody approved and reports success; a stale
`plan.py` writes a `plan.json` no pinned reader expects. Both runners therefore run
`chain-preflight.sh` FIRST and refuse to run on any mismatch — a drifted chain is a human's
decision, never a silent send. The pin covers exactly the six chain files: a partial manifest
is a failure, not a narrower check (one surviving `plan.py` pin once exited 0 while a stale
`send_variant_copy.py` kept posting copy nobody had approved).

Bumping the pin is a two-step, both in one PR:

```bash
# in a core-backend checkout whose scripts/ops/merge-queue/ you have read
git -C <core-backend> rev-parse HEAD
sha256sum <core-backend>/scripts/ops/merge-queue/{plan,variant_plan,send_variant_copy,clickup_merges,sql,same_person}.py
# publish the same bytes to the host, then on node-8:
scripts/merge-queue/chain-preflight.sh --chain-dir /root/q1    # must print "match"
```

## Running it by hand

An unflagged run posts real customer replies — the cron line passes no flag because sending
is the job:

```bash
# preview only, never sends
scripts/merge-queue/run-variant-queue.sh --dry-run

# what the cron does at 10:17Z (sends)
scripts/merge-queue/run-variant-queue.sh
```

## Stopping it without a deploy

```bash
touch /etc/hydra/merge-queue-variant.disabled   # no sends
touch /etc/hydra/merge-queue-census.disabled    # no plan refresh
```

## The 2026-11-05 defect this replaces

The hand-written variant line read
`plan.py clickup.json m1_sel.json > plan.daily.json && cp plan.daily.json plan.json`.
`plan.py:140` writes `plan.json` itself and lines 142-143 print only a ~267-byte summary,
so the redirect replaced the real (~450 KB) plan with the summary and every downstream
step read a summary as a plan. `run-variant-queue.sh` never redirects `plan.py`'s stdout
onto a plan file, and `scripts/tests/merge-queue-cron.bats` asserts the installed cron
invokes the runner and contains no such redirect.
