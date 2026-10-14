# clean-my-linux: the node-8 disk cleaner's orchestrator (MUS-6053)

`scripts/clean-my-linux.sh` (renamed from `weekly-cleanup.sh`) is the one unit
that **orders and gates** disk reaping on node-8. It owns rule order, the `df`
early-stop, the per-run caps, the apply gate, `flock`, and the single Slack
report. The policies stay in focused scripts, each with its own bats suite. The
script header is the authoritative reference; this page is the summary.

## Rule table (run in this order, cheapest-safe first)

| # | rule | implementation | notes |
|---|---|---|---|
| R1 | `/tmp` scratch allow-list | `scripts/tmp-reaper.sh` | allow-list, TTLs and `lsof` open-handle guard are the reaper's own. This script has no `/tmp` pattern logic. |
| R2 | agent + QA clone lanes | `scripts/sweep-workspace-clones.sh` | posts its own Slack summary too |
| R3 | codex/openclaw home | `scripts/codex-home-prune.sh` | a missing script is `skipped`, never an error |
| R4 | `.bak` / `.orig` > 30d | in-script | tight patterns (`*.bak`, `*.bak.*`, `*.bak-*`, `*.orig`), never `*.bak*` |
| R5 | `apt autoremove --purge` + `autoclean` | in-script | at most once per 24h; watermark `/var/lib/hydra/clean-my-linux/apt.last` (not `/opt/hydra`: the deploy rsync overwrites it) |

**Where the generic `/tmp` sweep went.** `/tmp` has two layers and neither is in
this script: allow-listed scratch within hours, open-handle guarded, is R1
(`tmp-reaper.sh`); everything else is the tmpfiles catch-all
`scripts/aux-units/tmp.conf` (`D /tmp 1777 root root mM:24h`: generic, mtime-keyed,
24h, recursive, daily timer), installed by `install-aux-units.sh`, which refuses a
source without the `mM:` prefix. It replaces the old weekly 14d depth-1 sweep and
reaps everything that sweep could. Regression test:
`tests/test_install_aux_units_tmpfiles.sh` (run in PR Validation).

## What only the orchestrator owns

- **Apply gate.** `--apply` is explicit; the default is a dry-run. The mode is
  passed to every delegate (`--dry-run` / `--apply`). A dry-run still posts its
  Slack report: that is how a first prod run is read.
- **`df` early-stop.** used% on `/` is read before each rule. At or below
  `CLEAN_MY_LINUX_TARGET_USED_PCT` (65) the run stops and records
  `target-reached-after=<rule>` (`none` if nothing was needed). An unreadable
  `df` fails closed to 100%.
- **Per-run caps.** `CLEAN_MY_LINUX_MAX_ENTRIES` (25000, top-level entries, not
  files) and `CLEAN_MY_LINUX_MAX_BYTES` (150 GiB). Reaching either stops the run,
  records `cap-hit=entries|bytes`, exits 0. R4 is checked per entry. A delegate
  is checked after it returns, from its own summary line, so one delegate can
  overshoot a cap by its own (already bounded) work.
- **Exit contract.** 0 normal (including cap-hit / target-reached); 1 structural
  refusal or delegate exit 1; 2 usage or delegate exit 2. The FIRST non-zero
  delegate rc is propagated after the summary and Slack post; later rules still run.

## Never touch

Anything outside the delegates' own allow-lists and R4's patterns; k8s/containerd
state; journald; `/var/lib/hydra-release`; `/etc/tmpfiles.d/tmp.conf`;
`/opt/hydra/audit`; `jest_0`.

## Rollout and rollback

The weekly unit (`hydra-weekly-cleanup.service`) now runs
`clean-my-linux.sh --apply`, because the default flipped to dry-run and the unit
must keep cleaning. Cadence and unit rename belong to MUS-6056. Run
`clean-my-linux.sh` by hand with no flag to read what a run would do.
Rollback: `systemctl disable --now hydra-weekly-cleanup.timer`; revert the
rename commit. The script keeps no state beyond the apt watermark file.
