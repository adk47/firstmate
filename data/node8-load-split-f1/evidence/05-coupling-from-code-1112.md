# Evidence 05 - what ties a job to the host the stores are on (from the code)

Source: `git grep` over this worktree at `466feac87` (branch base), 2026-11-12 16:36-16:40Z. Tests,
bats files and red-team fixtures excluded. This is a reading of the repo, not of the host: node-8
was running `8b9e7568` with a newer deploy in progress, so a line number here can differ from what
is deployed.

The question this answers: when a job uses the decision ledger or the proof store, what exactly
makes it need to be on the same machine as them?

## 1. No job runs one transaction across two stores

`git grep -i "attach database" -- scripts plugins` returns nothing outside tests.

So no code path commits to the ledger and the proof store in a single SQL transaction. Wherever a
job writes both, it is two separate commits on two files. "Atomic across ledger and proof store"
is not something the current code has; what it has is the three mechanisms below.

## 2. The stores are opened as local files

| module | how it opens the store |
|---|---|
| `scripts/credit_review/ledger.py:85` | `sqlite3.connect(self.path, timeout=30)` |
| `scripts/credit_review/verify_ledger.py:377` | `sqlite3.connect(path, timeout=30, isolation_level=None)`; a read-only `mode=ro` path at line 442 |
| `scripts/credit_trust/ledger.py:85` | `sqlite3.connect(self.path, timeout=30, check_same_thread=False)` |

There is no server in front of any store. Every reader and writer is a process that opens the
file itself. Two consequences, both documented SQLite behaviour rather than something measured in
this lane:

- The decision ledger is in WAL mode (evidence 02). WAL coordinates through a shared-memory file
  (`-shm`), which requires every process using the database to be on the same host. A reader on
  another machine over a network filesystem is not supported.
- The proof store is in rollback-journal mode (evidence 02). That depends on file locks, which are
  not reliable on network filesystems.

So "can this job run elsewhere" reduces to "does this job open one of these files". If it does, it
runs where the file is, or the store first has to stop being a bare file. That second option is the
data-durability decision the brief puts out of scope.

## 3. Host-local lock files

A `flock` only excludes processes on the same kernel. These are the ones the credit path uses:

| lock file | taken by |
|---|---|
| `/var/lib/hydra/credit-status-writes.lock` (`CV_CREDIT_WRITE_LOCK_PATH`) | `credit_review/decide.py:205`, `credit_review/fable_executor.py:67`, `credit_review/removal_executor.py:81` |
| `/var/lib/hydra/credit-review/apply.lock` | `credit_review/verify_notify.py:1021` (shared, non-blocking at line 1147) |
| `/var/lib/hydra/clickup-drain.lock` | `clickup_drain/write_path.py:65` (one lock over every queue drainer) |
| `$STATE/tick.lock` | `credit-verify-outbound.sh:479` |
| `$STATE_DIR/.lock` | `credit-digest-dm.sh:40`, `credit-jan-tray-dm.sh:38` |
| `$STATE_DIR/.kill-lift.lock` | `credit-approve-hold-lift.sh:148` |

Further `flock` users without a module-level path constant (path built at the call site, not
resolved here): `credit_review/need_asks.py:460`, `credit_review/uvn_status.py:1395`,
`credit_review/intercom_reconcile.py:876`, `clickup_drain/common.py:246`,
`credit_verify/docverify/name_index.py:139`, `credit_verify/docverify/pace.py:39`.

`credit-status-writes.lock` is the one that matters most: it is what stops the decider, the
executor and the removal executor from writing a credit's status at the same time. Move one of the
three to another host and that exclusion silently stops existing; nothing would fail, two writers
would simply both proceed.

## 4. Kill and enable files in `/etc/hydra`

76 non-test files under `scripts/` and `plugins/` refer to an `/etc/hydra/*.disabled` or
`*.enabled` file or a kill-file variable. Most-referenced paths (count of references):

| path | refs |
|---|---|
| `credit-trust-score-approve.disabled` | 22 |
| `credit-trust-decide.disabled` | 15 |
| `credit-ops-notes.disabled` | 14 |
| `credit-verify.disabled` | 12 |
| `gmail-readers.disabled` | 11 |
| `churn-risk.disabled` | 9 |
| `fable-decider.disabled` | 6 |
| `jev.disabled`, `gdpr-pipeline.disabled`, `fable-trays.disabled`, `credit-verify-notify.disabled` | 5 each |

At least 40 distinct kill or enable paths appear (the listing was cut at 40).

A kill file is a file on node-8's root disk. A job on another host does not see it. This is the
"a switch in one place is not a switch" failure the repo's `AGENTS.md` already records from 10-27.

## 5. Code that names both the ledger and the proof store

Eleven non-test files refer to both: `scripts/credit-review.py`, `scripts/credit-doc-close.py`,
`scripts/credit_review/decide.py`, `scripts/credit_review/need_asks.py`,
`scripts/credit_review/comm_state.py`, `scripts/credit_review/claim_proof_ask.py`,
`scripts/credit_review/receipts.py`, `scripts/intercom-verify-request.sh`,
`scripts/intercom-backlog/send.py`, `scripts/churn/sources.py`,
`scripts/prove-coded-decider-invalidation.py`.

Naming both is not the same as writing both. Which of these write and which only read was not
resolved from the code; the open-file sampler (evidence 07) records the open mode of each process
that actually ran.

## 6. Where a model provider is called from

Files that reach a model provider (OpenRouter, OpenAI, or the codex judge wrapper), excluding
validators, auth plumbing and watchdogs:

| caller | used for |
|---|---|
| `scripts/lib/model_chain.py` | the two-tier chain every user-affecting call is meant to go through |
| `scripts/lib/codex-judge-exec.sh`, `scripts/lib/jev.sh` | the tool-less subscription judge |
| `scripts/credit_trust/llm.py` | credit-trust calls, each logged to `llm_calls` |
| `scripts/credit_review/judge.py`, `batch_judge.py`, `proof_verifications.py` | credit review judging |
| `scripts/credit_verify/docverify/extract.py` | document claim extraction |
| `plugins/intercom/src/judge.ts`, `jev-client.ts` | the edge plugin's judge |
| `scripts/dr-ai-healer.sh`, `scripts/release-watch.sh`, `scripts/support-changelog-sync.sh`, `scripts/prod-log-alert-watchdog.sh`, `scripts/lib/describe-creative.sh` | operations, not user decisions |

Plus the two gateways themselves, whose agent turns call the model from inside the gateway
process; that call site is in openclaw, not in this repo.

What this shows for the map: the model call is already an outbound HTTPS request or a subprocess.
It reads no store. The job around it does. So the model call is not what holds a credit job on
node-8; the store files, the lock files and the kill files are.

## What was not established here

- Which of the scheduled commands take which lock at run time (this is a static read).
- Whether any job holds a store transaction open across a model call. If one does, a slow model
  holds a write lock on a file other jobs need. Not checked.
- The lock paths for the six call-site-built locks listed in section 3.
