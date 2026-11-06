# `data/sentinel/` — proposals, and how automatic demotion works

Owner: `scripts/sentinel/` (dispatch `sentinel-demote-s6`, ruling
`request-sentinel-fable-s1` §2.3/§2.6/§5). The capability registry itself is
`policies/sentinel-capabilities.json` (delivered by `sentinel-core-s0`).

## Three independent stops

A capability stops working if **any one** of these is true. They are separate on
purpose: each has a different owner and a different failure mode.

| stop | where it lives | who flips it | what breaks it |
|---|---|---|---|
| rollout state | `policies/sentinel-capabilities.json` (repo) + `/var/lib/hydra/sentinel/registry-state.json` (host) | `scripts/sentinel/demote.py` narrows the host; a human PR widens it | deploy restores the repo state — which is why a demotion can never live only on the host |
| kill file | `/etc/hydra/<kill_file>` from the registry row | `demote.py` (drops it), a human (removes it) | nothing: the actor's own runner reads it before every tick |
| actor's approval flag | `policies/credit-approval-automation.json` → `approved` | a human, in the same PR that mirrors a demotion | `demote.py` deliberately does not touch it |

`effective_state()` takes the **stricter** of repo and host, so a stale host
row can only ever narrow what the repo allows — a demotion survives a deploy
that predates it, and a promotion cannot be smuggled in through the host file.

## What trips a demotion

`demote.py run` joins the last 7 days per registered capability (`--fast` uses
only the first two, because a manipulated action is a live incident):

| trigger | source | default threshold |
|---|---|---|
| `reverts_7d` | ACTION-AUDIT `action_ledger` rows with `reverted_at` (revert rows themselves excluded) | 5 |
| `manipulated_7d` | watcher `audit_verdicts.verdict = 'manipulated'` | any |
| `contradicted_7d` | `contra_appr` from fraud-lens, or derived from `decisions` contradicted by a later trusted source / validator decline | 3 |
| `complaints_7d` | Intercom complaint tags on the capability's conversations | 10 |
| `spot_audit_fails` | Fable 2-hourly sample | any |
| `overdue_pct` | `waiting_on=us` rows past `due_at`, as a share of that day's rows | > 5 % |

Thresholds come from the row's own `demotion` block, never from this file.
Per-day hot counters and the 5 % rule are in `scripts/sentinel/outcomes.py`.

CI validates that block (`_demotion_problems`): every key must be a trigger the
demoter implements, numeric thresholds must be numbers > 0, and `audit_fail_any`
must be the boolean `true`. A typo'd key or a string threshold is a stop that
does not exist — `_rule_hits()` ignores it, so the row would ship with 99 reverts
and a manipulated verdict and never demote.

The revert ledger and the watcher verdicts are collected **independently**. A
missing or malformed `action_ledger` table is a fact about reverts, never about
verdicts: it used to return early and skip the verdict read, so a store with a
fresh `manipulated` verdict and no usable ledger recorded nothing and the
strongest signal could not demote.

**Unmeasured is not healthy.** Every source reports `ok` / `absent` /
`unknown`. An absent source cannot fire a trigger, so it never demotes — and it
also never excuses: the nightly digest lists each capability whose declared
trigger has no source behind it, promotion is blocked while any trigger is
unmeasured, and a missing registry pages once a day instead of passing quietly.

## Demotion is one step, promotion is never automatic

```
shadow ← canary ← live          demote.py steps LEFT, one hop, per tick
```

A trip flips the host row one step (`live → canary`, `canary → shadow`; a
`shadow` row stays `shadow`), drops the kill file, pages `#clio_devops` with
counts (never account names), appends `/var/lib/hydra/sentinel/demotions.jsonl`,
and opens a PR that mirrors the flip into `policies/sentinel-capabilities.json`.
Deduped for 24 h, so a repeating condition does not page every hour.

```bash
python3 scripts/sentinel/demote.py digest                     # 7-day counters for every row
python3 scripts/sentinel/demote.py run --dry-run --no-pr      # render the tick, change nothing
python3 scripts/sentinel/demote.py promote --capability <id> --ruling <fable-ruling-id>
```

`promote` **renders a parity report and changes nothing**. It gates on ≥ 7 days
since `rollout.since`, ≥ 200 evaluations, ≥ 99 % agreement with the arm it
replaces, 0 false acts on RED/BLACK, 0 blast-radius cap trips, 0 demotion
triggers, and a cited ruling id. The PR that actually flips a state upward must
carry `rollout.since` and `rollout.approval_ref`; `scripts/check-sentinel-registry.py`
enforces that in CI (the fixture registry is not validated — the live file is).

Those two fields must be **new for this promotion**: the gate compares them with
the base row and refuses a state-only edit that reuses the previous ruling. A
`canary` row already cites the ruling that authorized the canary step, so
without the comparison, editing `rollout.state` alone would launder that old
ruling into a `live` promotion.

## Weekly proposals

`sentinel-propose.timer` (Sun 02:00Z) clusters the last 30 days of
`unhandled` / hand-off rows into `YYYY-WW-<slug>.md` here plus a `shadow`
registry row, and opens one PR per proposal.

- De-identified features only: class, sub-class, requested action, counts. No
  conversation ids, no account ids, no message text.
- **Caller text is dropped, not quoted.** The evaluation store is fed by callers,
  so a field is published only when a vocabulary this repo OWNS names it
  (`_vocabulary` / `_code_token`): the class table, plus every `class`,
  `sub_class`, `action.requested` and `action.endpoint` a reviewed registry row
  declares. **Shape is not the boundary** — no regex can separate `user_12` from
  `R12`, and every shape rule we tried let a short alphabetic account id
  through. The vocabulary grows by a registry PR, never by whatever a caller
  wrote into the evaluation store. Anything else becomes `unknown`
  (class/sub-class) or is withheld with a line saying so (`requested_action`) —
  including in the committed filename, which is built from the same de-identified
  view. Two raw clusters that redact to the same view are merged (volume summed,
  forced flag OR-ed) rather than overwriting each other.
- **No model is called in this lane.** The proposal text is a template; a
  cluster's proposed `action.type` is a deterministic lookup
  (`CLASS_TYPE_DEFAULTS` / `CLASS_WORD_TYPES`), defaulting to `handoff`.
- Money, legal, credentials and irreversible classes are forced to `handoff` by
  code (`_is_forced_class`), not by prose in the proposal. That fence reads the
  **raw** values before any redaction — redacting first would let a prose
  sub-class hide a money cluster and propose an actor type for it — and it reads
  the requested action too, so `class=credit, sub_class=normal,
  requested_action=refund` is a handoff rather than an actor.
- A proposal is `shadow`, so it evaluates and decides nothing until a ruling
  promotes it.

## Operations

```bash
touch /etc/hydra/sentinel-demote.disabled   # stop the demote tick only
touch /etc/hydra/sentinel.disabled          # stop the whole sentinel (demote + propose)
tail -f /var/log/hydra-sentinel-demote.log  # both units log here
cat /var/lib/hydra/sentinel/registry-state.json
```

Both switches are checked before anything is evaluated, so neither one ever
leaves a capability changed. A switched-off detector is not a healthy one: the
digest keeps reporting the triggers it could not measure, and promotion stays
blocked, for as long as a switch is set.

Units: `sentinel-demote.timer` (nightly 02:30Z), `sentinel-demote-fast.timer`
(hourly), `sentinel-propose.timer` (Sun 02:00Z), installed by
`scripts/install-aux-units.sh` and pinned by
`scripts/tests/install-aux-units-sentinel-demote.bats`. Exit codes:
`0` nothing tripped · `1` error · `2` the registry has not landed yet (clean skip) ·
`3` kill switch · `4` the registry exists but is unusable (malformed, or an unreadable
host runtime state) · `10` tripped and demoted.

`10`, `2` and `3` are in `SuccessExitStatus=`, because a demotion is not a failure,
"S0 has not merged the registry yet" is not either, and an intentional kill switch is
a deliberate, log-only stop — paging hourly about a switch a human set on purpose is
how an alert channel gets ignored. `scripts/tests/install-aux-units-sentinel-demote.bats`
reads the exit codes out of `demote.py` and fails if a normal code is missing from the
units or a failure code (1, 4) is whitelisted, so this cannot drift apart again.

**The units do NOT gate on the registry** (no `ConditionPathExists`). A condition
makes a missing registry a silent skip in every case, which is right before S0 and
wrong afterwards: a deleted or failed-to-deploy registry would leave automatic
demotion blind with no page and no failed unit. `demote.py` distinguishes the two
itself, using the `registry-seen` marker it writes on every successful load:

- never loaded one → exit `2`, clean skip (the pre-S0 world, and `2` is in
  `SuccessExitStatus=` so it never fails);
- loaded one before, gone now → page + exit `4`, because the loop is blind.

Exit `4` stays a failure on purpose: a registry that exists but cannot be read, or
one that vanished after a good load, means every capability in it is silently
un-demotable. That pages through `hydra-unit-failed@`.

CI refuses a `canary`/`live` row whose `kill_file` no production code actually
checks (`scripts/check-sentinel-registry.py`). "Checked" means the path is not in a
comment (including an INLINE comment: `KILL = "<path>"  # .exists()` is prose, not a
check) AND either the line itself performs an existence check, or the path is
bound to a name that is existence-checked in the same file, or in a file that
**imports the binding's module** and checks it as `module.NAME.exists()` — the
definition and the check genuinely live apart (`credit_review/decide.py` binds
`KILL_SWITCH`, `credit-review.py` imports `decide` and calls
`decide.KILL_SWITCH.exists()`). A bare name match across unrelated files is not
evidence: `UNUSED = Path(<path>)` in one file plus an unrelated `UNUSED.exists()`
in another proves nothing. A path that appears only in prose, in a docstring, or
in a test is not a stop.

## A deleted registry is a gate failure

The gate accepts a missing registry only when it was also missing on **base**: that is
the pre-S0 state, where `sentinel-core-s0` has not merged the file yet. Once the
registry exists on base, deleting it makes every sentinel unit exit 2 (a clean skip),
which silently disables automatic demotion — so
`scripts/check-sentinel-registry.py --base <ref>` fails instead. Without `--base` the
run cannot tell "not landed yet" from "deleted" and says so in its output.

## Every source must be attributable

A source that cannot name the capability an outcome belongs to is `unknown`, never
`ok`: an evaluation table with `at`/`waiting_on`/`due_at` but no `capability_id` can
show sixty overdue rows and still demote nobody, so reporting it as healthy would
render an unmeasurable `overdue_pct` trigger as a measured, quiet one. `unknown` keeps
the trigger from firing and blocks promotion.

## Promotion parity refuses to read an absent measurement as a clean one

`promote` renders these gates; a value the store cannot supply is `UNMEASURED`, and
`UNMEASURED` never passes:

| gate | requirement |
|---|---|
| `evidence_window` | `rollout.since` is >= 7 days old |
| `evaluations` | >= 200 evaluations in the window |
| `agreement` | >= 99 % over >= 100 **paired** rows that cover >= 50 % of the window |
| `false_act` | 0 acts on RED/BLACK bands, measured from real `band` + `decision` columns |
| `cap_trips` | 0 blast-radius cap trips |
| `demotion_triggers` | no trigger fired in 7 d, from measured counters |
| `ruling` | a Fable ruling id is cited |

The paired floor and the coverage floor exist because 1 paired row out of 200 renders
as "100.00 % agreement", and a store with no `agreed` / `band` / `decision` column
renders as "no paired rows" and "0 false acts of 0 rows". Both are a missing
measurement wearing a passing verdict.

## Concurrency: one host lock for every sentinel tick

The hourly `--fast` tick and the nightly tick both load, mutate and save the WHOLE
runtime document, and both use the same mirror checkout. Unserialized, a fast tick
that loaded before a nightly demotion saves its own snapshot over it, erasing the
other capability's host stop until its mirror PR merges.

`HostLock` (`SENTINEL_LOCK_FILE`, default `/var/lib/hydra/sentinel/run.lock`) is an
`flock` held across load → evaluate → save → mirror PR. `flock`, not a pid file: the
kernel releases it when the process dies, so a killed tick cannot wedge the sentinel.
A tick that cannot get the lock within `SENTINEL_LOCK_TIMEOUT` (default 300s) logs and
exits **0** — the other tick is running the same join, so skipping is not a failure.
An **unusable** lock (missing or unwritable state dir) is different: it exits **1** and
fails the unit, because skipping there would switch the sentinel off while looking
healthy. The units set `TimeoutStartSec=900` so systemd's 90s default cannot SIGTERM a
tick mid-join.

The mirror PR needs a real git checkout (`/opt/hydra` has no `.git`); the
installer keeps one at `/var/lib/hydra/sentinel/mirror-repo`. `gh pr create` runs
inside that checkout with an explicit `--repo`, because a unit runs with cwd `/`
and `gh` would otherwise refuse to infer the repository. If the checkout is
missing the demotion still happens — the host stops the capability — and the
missing PR pages.

The registry file is edited only AFTER `open_pr()` has switched the checkout to
`origin/main`. Writing it first looks equivalent and is not: while a previous
demotion's PR is unmerged, `origin/main` still carries the old blob, so git
refuses the branch switch over the dirty file (`Your local changes would be
overwritten by checkout`) and every second demotion loses its mirror PR. A
`reset --hard` before the switch also clears anything a killed tick left behind.

Tests: `python3 -m unittest -v tests.test_sentinel_demote` (stdlib only; seeded
stores in a temp dir, no host path, no network, no Slack).
