# The unattended merge queue

A pull request that is green, QA-passed, and merge-ready still waits for a firstmate turn in most homes: the merge queue is a file, and its batch is run by hand.
`bin/fm-merge-queue.sh` is that batch on a timer.
A systemd user timer runs it every ten minutes, and a queued pull request lands without anyone being woken.

This page owns the operator's view: the queue file, the decision the timer makes, the records it writes, and the one line a day it reports.
The script's own header and `--help` own the exact flags, environment variables, and the conditional detail behind each verdict, and `bin/fm-pr-merge.sh` owns what a merge actually does.

## Enable it in one home

The queue is opt-in per home and off until its file exists.

```sh
# 1. write the queue: one row per pull request
mkdir -p data
cat > data/go-queue.txt <<'EOF'
# owner: <github-login>
widgets 1580 e672a82e encore-t1 squash # Fable GO
EOF

# 2. check the decisions it would make, then install the timer
bin/fm-merge-queue.sh run --dry-run
mkdir -p ~/.config/systemd/user
bin/fm-merge-queue.sh unit service > ~/.config/systemd/user/fm-merge-queue.service
bin/fm-merge-queue.sh unit timer   > ~/.config/systemd/user/fm-merge-queue.timer
systemctl --user daemon-reload
systemctl --user enable --now fm-merge-queue.timer
```

The generated service puts `%h/.local/bin` on the timer's `PATH`, because a systemd user manager's own `PATH` does not include the tools firstmate installs there.
A run refuses at startup, with the tool named and the `PATH` it saw, when `gh` or `gh-axi` is not resolvable rather than reporting every row as an unanswered forge, so a tool installed elsewhere needs its own directory added to the unit's `Environment=PATH`.

`bin/fm-merge-queue.sh status` prints the queue size and the most recent run from the timer's own records, with no network call.
`systemctl --user list-timers fm-merge-queue.timer` says whether the timer is armed.
To stop it, `systemctl --user disable --now fm-merge-queue.timer`; the queue file keeps its rows, so re-enabling resumes the same work.

## The queue file

One row per pull request, whitespace separated:

```
<repo> <number> <expected-head> <task-id> <squash|merge|rebase> [# provenance]
```

- `<repo>` is `owner/repo`, or a bare repository name that uses the owner from a `# owner: <login>` directive in the same file, or `FM_MERGE_QUEUE_OWNER`.
- `<number>` is the pull request number.
- `<expected-head>` is the head commit the row was written against, at least seven hex characters.
- `<task-id>` is the firstmate task the merge is recorded against, which keeps the merge metadata and the landed-work check working.
- `<method>` is the merge method handed to the forge.
- `[# provenance]` is an optional trailing comment, kept exactly as written. It is where the row records its own history, including the Fable GO that authorizes the merge (below). Any other sixth field makes the row unusable, because a row this home cannot read must never be guessed at.

A row is identified by its owner, repository, number, and expected head, so `acme/widgets 12` and `beta/widgets 12` are two independent rows and so are two heads of one pull request.
When one pull request appears twice, the newest row supersedes the older-head row: the superseded row is recorded in the ledger and the daily detail file with its own verdict rather than dropped, and the newest row is the one that decides.
A head that has moved retires the row rather than merging a commit nobody queued, so re-queue after a push.
Comments and blank lines are preserved exactly as written, and an exact duplicate of one row is attempted once.
A queue file edited while a tick is running is never overwritten: the run leaves its rewrite for the next tick and says so.

## What merges, and what never does

Every row is read live on every tick; nothing in the queue file is trusted as current.
A row merges only when the pull request proves it is ready: open, not a draft, at the head the row named, every check green, and a `qa-review` check passing on that exact head.
That QA requirement has no configuration switch, so no home can turn it off.
Two `qa-review` checks may exist; a failing instance holds the row.

Four things keep a change away from an unattended timer and with a decider instead: a fence label naming money, credentials, a vendor console, customer copy, or irreversible work; a title or body that mentions production DDL; a draft; and a red head.
None of those rows merges, and a fenced one leaves the queue with its reason.

## The admin bypass is proven, not assumed

The merge is handed to `bin/fm-pr-merge.sh` with `--admin`, which bypasses the forge's own review and required-check gates.
That is deliberate: the account cannot approve its own pull requests, so the queue proves the three things that replace a human approval before it uses the bypass, and records what it bypassed.

1. A `qa-review` check passing on the exact head, with no configuration switch.
2. A Fable GO recorded on the row for this head, as a `fable-go` marker in the row's trailing comment.
   The marker is read case-insensitively with `-`, `_`, or a single space as the separator.
   A GO binds to a head only when written `Fable GO @<sha>` or `Fable GO =<sha>`, and that sha must prefix this head, so a GO written for an older head does not carry over a push.
   Any other text after the marker is provenance prose the queue does not interpret.
   A negated or pending form such as `awaiting Fable GO`, `Fable GO pending`, or `Fable GO - no-go` is not a GO.
   Negation is read only from the marker's immediate neighbours, so `Fable GO - no blockers` is still a GO.
3. Every required status check the base branch registers, present and passing, from both classic branch protection and repository rulesets.

Anything unproven keeps the row queued and spends no attempt budget, because an unproven gate is not a refused merge.
An unprotected base branch is a successful read of "nothing required"; a registration the forge cannot answer for is unproven, not empty.

One check is exempt from the required-check proof because it is red or absent by design on the changes it guards, and it is named in the bypass record of every merge that relied on it:

- `credit-approval-guard` - red by design on a credit-impact change, where the credit review itself is the gate.
  A failing instance is the waiver, and a guard that has not finished holds the row.

Every admin merge records the protections it bypassed on its own line, in the ledger, and in the daily detail file, as `admin bypassed: <list>`, where the list names `review-required` or `changes-requested` when the forge still wanted a review and each by-design check that was not passing.
A merge that relied on the credit-guard exemption also says `credit-guard waived` in the same places, so neither the waiver nor the bypass is ever silent.

A row leaves the queue only on a terminal verdict: merged, already merged, closed, fenced, a moved head, superseded by a newer row for the same pull request, or `FM_MERGE_QUEUE_MAX_ATTEMPTS` consecutive refused merge attempts (default 6), which retires it as abandoned.
A row that is merely not ready stays queued and is retried on the next tick.
So does a row this home cannot read at all, such as one with no repository owner, an unknown merge method, or a task id that names no task in this home, because a configuration mistake must never delete the queue it was given and must never spend a retry budget.

The merge itself is always `bin/fm-pr-merge.sh`, so that script's refusal rules, merge verification, metadata recording, and durable wake still apply; the timer only decides what to hand it.

## Records and the daily line

Records live under `<FM_HOME>/state/merge-queue/`:

- `ledger.tsv` - one line per verdict: `<epoch> <row> <verdict> <reason> <url>`, where a row is named by its pull request and the head it was queued at, as in `acme/widgets#12@e672a82e`, and a row with no usable head is named by its pull request alone.
- `daily-<YYYY-MM-DD>.txt` - every merged and retired row of the summary window, one per line, with its time, row, verdict, reason, and full pull request URL.
- `last-run` - the verdict counts of the most recent run, including how many rows were held for a missing Fable GO, which is what `status` prints.
- `.summary` - the day of the last daily line and the epoch it covered from.
- `.lock/` - single-instance lock, so two ticks never merge at once.

The summary window starts strictly after the epoch of the previous summary, so a merge recorded in that same second is reported once rather than twice.

The first run of each UTC day appends one durable check wake giving the counts and the path of that day's detail file, which is how the queue reaches firstmate's chat as one line a day instead of a wake per merge.
No row list is truncated into the line itself, so nothing disappears off the end of a busy day.
That line also says how many rows need the queue file fixed, and how many merges relied on the credit-guard exemption.
`status` additionally reports how many rows the last run held for a missing Fable GO, so a queue that is waiting on a decision is never mistaken for a queue that is waiting on the forge.
No run pages anyone directly; every other verdict is a journal line.

## Limits

- It is a systemd user timer, so it runs inside your user session; on a machine you are not logged into, enable lingering with `loginctl enable-linger <user>` so it keeps running after logout.
- `OnBootSec=2min` restarts it shortly after a reboot.
- It merges only what the forge can already merge: no rebase, no conflict resolution, no re-review.
- A branch that falls behind is retried on each tick until its head moves, a decider intervenes, or the retry budget retires it as abandoned.
- A queued pull request the forge can no longer answer for stays queued and is retried every tick; remove such a row from the file by hand.
- A row whose task id names no task in this home stays queued as unusable, so the fix is to correct the row rather than to wait.
