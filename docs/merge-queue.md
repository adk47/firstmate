# The unattended merge queue

A pull request that is green, QA-passed, and merge-ready still waits for a firstmate turn in most homes: the merge queue is a file, and its batch is run by hand.
`bin/fm-merge-queue.sh` is that batch on a timer.
A systemd user timer runs it every ten minutes, and a queued pull request lands without anyone being woken.

This page owns the queue file, the decision the timer makes, the records it writes, and the one line a day it reports.
`bin/fm-merge-queue.sh --help` owns the exact flags and environment variables, and `bin/fm-pr-merge.sh` owns what a merge actually does.

## Enable it in one home

The queue is opt-in per home and off until its file exists.

```sh
# 1. write the queue: one row per pull request
mkdir -p data
cat > data/go-queue.txt <<'EOF'
# owner: <github-login>
widgets 1580 e672a82e encore-t1 squash
EOF

# 2. check the decisions it would make, then install the timer
bin/fm-merge-queue.sh run --dry-run
mkdir -p ~/.config/systemd/user
bin/fm-merge-queue.sh unit service > ~/.config/systemd/user/fm-merge-queue.service
bin/fm-merge-queue.sh unit timer   > ~/.config/systemd/user/fm-merge-queue.timer
systemctl --user daemon-reload
systemctl --user enable --now fm-merge-queue.timer
```

`bin/fm-merge-queue.sh status` prints the queue size and the most recent run from the timer's own records, with no network call.
`systemctl --user list-timers fm-merge-queue.timer` says whether the timer is armed.
To stop it, `systemctl --user disable --now fm-merge-queue.timer`; the queue file keeps its rows, so re-enabling resumes the same work.

## The queue file

One row per pull request, whitespace separated:

```
<repo> <number> <expected-head> <task-id> <squash|merge|rebase>
```

- `<repo>` is `owner/repo`, or a bare repository name that uses the owner from a `# owner: <login>` directive in the same file, or `FM_MERGE_QUEUE_OWNER`.
- `<number>` is the pull request number.
- `<expected-head>` is the head commit the row was written against, at least seven hex characters.
- `<task-id>` is the firstmate task the merge is recorded against, which keeps the merge metadata and the landed-work check working.
- `<method>` is the merge method handed to the forge.

A head that has moved retires the row rather than merging a commit nobody queued, so re-queue after a push.
Comments and blank lines are preserved exactly as written, and a repository listed twice in one tick is attempted once.

## What merges, and what never does

Every row is read live on every tick; nothing in the queue file is trusted as current.
A row merges only when the pull request proves it is ready: open, not a draft, at the head the row named, every check green, and a `qa-review` check passing on that exact head.
`FM_MERGE_QUEUE_QA=optional` waives the QA requirement for repositories that run no QA workflow.

Four things keep a change away from an unattended timer and with a decider instead: a fence label naming money, secrets, a vendor console, customer copy, or irreversible work; a title or body that mentions production DDL; a draft; and a red head.
None of those rows merges, and a fenced one leaves the queue with its reason.

A row leaves the queue only on a terminal verdict: merged, already merged, closed, fenced, a moved head, or `FM_MERGE_QUEUE_MAX_ATTEMPTS` consecutive refused merge attempts (default 6).
A row that is merely not ready stays queued and is retried on the next tick.
So does a row this home cannot read at all, such as one with no repository owner or an unknown merge method, because a configuration mistake must never delete the queue it was given.

The merge itself is always `bin/fm-pr-merge.sh`, so that script's refusal rules, merge verification, metadata recording, and durable wake still apply; the timer only decides what to hand it.

## Records and the daily line

Records live under `<FM_HOME>/state/merge-queue/`:

- `ledger.tsv` - one line per verdict: `<epoch> <key> <verdict> <reason>`.
- `last-run` - the verdict counts of the most recent run, which is what `status` prints.
- `.summary` - the day of the last daily line and the epoch it covered from.
- `.lock/` - single-instance lock, so two ticks never merge at once.

The first run of each UTC day appends one durable check wake summarizing what landed and what was retired since the previous one, which is how the queue reaches firstmate's chat as one line a day instead of a wake per merge.
That line also says how many rows need the queue file fixed.
No run pages anyone directly; every other verdict is a journal line.

## Limits

- It is a systemd user timer, so it runs inside your user session; on a machine you are not logged into, enable lingering with `loginctl enable-linger <user>` so it keeps running after logout.
- `OnBootSec=2min` restarts it shortly after a reboot.
- It merges only what the forge can already merge: no rebase, no conflict resolution, no re-review.
- A branch that falls behind is retried every tick until its head moves or a decider intervenes.
- A queued pull request the forge can no longer answer for stays queued and is retried every tick; remove such a row from the file by hand.
