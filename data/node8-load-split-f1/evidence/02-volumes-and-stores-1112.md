# Evidence 02 - volumes and data stores (read-only)

Source: `ssh root@40.160.32.80` (ovh-node-8), 2026-11-12 16:03-16:06Z. Nothing was written on the host.
Every sqlite read used `file:<path>?mode=ro`. `du` ran under `nice -n 19 ionice -c3`.
Deployed sha: `8b9e7568afbb75c070b66411c9c788a7d35be3cb` (it was `87027e74` a day earlier).
Host at 16:03:12Z: load average 3.03 / 2.76 / 2.53.

## There is one host volume

- `/dev/nvme0n1p3`, ext4, mounted `/`, 889.3G. Every host path below is on it.
- `nvme1n1` (894.3G) has no partition and no mountpoint in `lsblk`. Its use (Longhorn, spare) was not determined.
- `sda`-`sde` (1-2G each) are Longhorn CSI volumes mounted into k3s pods, not host stores.

So "which volume" is the same answer for every host service: the root filesystem of node-8. What
differs between services is which **files** on it they own, and that is what the rest of this
file measures.

## Two corrections to the task brief, measured

1. **The ledger is not at `/var/lib/credit-trust/ledger.sqlite3`.** That path does not exist.
   `/var/lib/credit-trust/` holds JSON inputs (39M total: `proof-on-file.json` 14.4M,
   `org-affiliation.json` 4.7M, `self-removals.json` 2.5M, `paying-users.json`) and two
   zero-byte sqlite files. The store matching the brief's description is
   **`/var/lib/hydra/credit-review/ledger.sqlite3`**: 873,021,440 bytes (833 MiB), `decisions` =
   **1,012,654** rows (brief: 827MB, 964k). A second, unrelated file named `ledger.sqlite3` lives at
   `/var/lib/hydra/credit-trust/ledger.sqlite3` (18.3M, one table `llm_calls` = 9,608 rows).
2. **The proof store is in rollback-journal mode, not WAL.** `proof.sqlite` reports
   `journal_mode=delete`, so a writer takes a whole-file lock. The decision ledger is `wal`.

## Stores over 1 MiB

| path | bytes | journal mode | last write (UTC) | row counts measured |
|---|---|---|---|---|
| `/var/lib/hydra-credit-verify/doc-verify.sqlite` | 2,705,428,480 | wal | 11-12 15:52 | not counted |
| `/var/lib/hydra-credit-verify/proof.sqlite` | 1,273,323,520 | **delete** | 11-12 15:05 | forensics 1,395,979; verdicts 336,506; fingerprints 71,290; stage2_shadow 48,608; proof_intake 9,533; proofs 9,503 |
| `/var/lib/hydra/credit-review/ledger.sqlite3` | 873,021,440 | wal | 11-12 15:50 | decisions 1,012,654; decision_outcomes 317,111; request_state_log 104,576; request_state 92,861; verify_requests 75,023; reviews 35,517; verify_messages 12,891; decision_told 3,499 |
| `/var/lib/hydra-credit-verify/dsp-verify.sqlite` | 809,246,720 | delete | 11-12 15:41 | not counted |
| `/var/lib/hydra-credit-verify/name-index.sqlite` | 249,790,464 | delete | 11-12 09:54 | not counted |
| `/var/lib/hydra/request-comms/state.sqlite` | 186,257,408 | delete | 11-12 15:48 | not counted |
| `/var/lib/hydra/credit-review/drain.sqlite` | 36,622,336 | wal | 11-11 18:41 | not counted |
| `/var/lib/hydra/credit-trust/ledger.sqlite3` | 18,321,408 | delete | 11-12 14:28 | llm_calls 9,608 |
| `/var/lib/hydra/churn/support-state.sqlite` | 10,047,488 | not read | 11-12 04:46 | not counted |
| `/var/lib/hydra/sentinel/evaluations.sqlite` | 7,729,152 | wal | **11-05 00:53** | not counted |
| `/var/lib/hydra/caroline-monitor/monitor.sqlite` | 5,050,368 | not read | 11-12 15:41 | not counted |
| `/var/lib/hydra-gdpr/erasure.sqlite` | 1,781,760 | delete | 11-12 15:31 | not counted |

Also on disk next to the ledger, not live stores: `ledger.sqlite3.pre-repair-20261111T222707Z`
(842M) and `ledger.pre-claimkey-20261110.sqlite3` (722M) - two full copies, 1.56G.

`sentinel/evaluations.sqlite` was last written seven days before this measurement. Whether the
sentinel passes are running was not established here.

## Directory sizes (apparent)

| path | size |
|---|---|
| `/var/lib/hydra-credit-verify` | 8.8G |
| `/var/lib/hydra` | 4.5G |
| `/var/lib/hydra-release` | 2.5G |
| `/var/lib/credit-trust` | 39M |
| `/var/lib/hydra-qa` | 28M |
| `/var/lib/hydra-gdpr` | 3.2M |
| `/etc/hydra` | 6.4K |

`/opt/hydra`, `/root/.openclaw-main` and `/root/.openclaw-edge` were not re-measured in this step
(151G / 63G / 16G on 2026-10-27, from the earlier node8-to-pods report, not from today).

## Who holds a store open (point-in-time, 16:03Z)

Scan of `/proc/*/fd` for `*.sqlite`, `*.sqlite3`, `*.db` and their `-wal` / `-shm` files:

- `openclaw-gateway-main`: its own `/root/.openclaw-main/**` stores only (per-agent
  `openclaw-agent.sqlite`, `codex-home/*.sqlite`, `state/openclaw.sqlite`).
- `openclaw-gateway-edge`: its own `/root/.openclaw-edge/**` stores only (`support` agent,
  `state/openclaw.sqlite`, lock files).
- `muso-mcp-gate`: `/opt/muso-mcp-gate/data/muso-mcp-auth.db`.
- **No process held the decision ledger, the proof store, or any other `/var/lib/hydra*` store
  open at that instant.**

That last line is a measurement of one instant, and it is the expected shape: the credit jobs are
short-lived children that open, write and exit. It means the writers cannot be read off open file
descriptors. They have to be established from the scheduled commands and the store paths those
commands resolve, which is the next step.

It does establish one thing directly: **neither long-running gateway process keeps the ledger or
the proof store open.** Caroline's edge process touches them only through child commands, if at all.

## Kill and hold files present in `/etc/hydra` (names only)

Active: `credit-trust-decide-provisional-paid.disabled`, `credit-verify-outbound.disabled`,
`fable-decider.disabled`. Enable flags: `credit-review-model.enabled`,
`credit-verify-outbound.paid-enabled`. The other 9 of the 14 matching entries are renamed
history (`*.cleared-*`, `*.lifted-*`). The filter was names containing `disabled`, `enabled` or
`held`; files in `/etc/hydra` with other names (env files, for example) were not listed.

These are files on the same root filesystem. Any job that honours one must be able to read
`/etc/hydra` on the host it runs on.
