# Instrument sweep

Repeatable evidence for `bin/fm-instrument-sweep.sh`, the sweep that finds checks whose output does not depend on their input.
The command's header owns the defect classes, damage weights, TSV schema, probe contract, and the `[source: ...]` snippet on every finding.
This record owns the proof that the sweep can report dirty at all, and the live-state report that names the follow-up work.

The only test that matters for a defect finder is that it names a planted defect, so the fixture proof runs against `tests/fixtures/instrument-sweep/`.
Each fixture carries a `# planted-defect: <class>` comment on the line above its defect, so the expected line is derived rather than hardcoded.

- Date: 2026-11-08
- Shell: bash 5.2.21, shellcheck 0.11.0
- Comparison base: `origin/main` at `c2052b51`

## The sweep names all seven planted defects

`bin/fm-instrument-sweep.sh --state tests/fixtures/instrument-sweep/planted --probe-dir tests/fixtures/instrument-sweep/planted`

```console
$ bin/fm-instrument-sweep.sh --state tests/fixtures/instrument-sweep/planted --probe-dir tests/fixtures/instrument-sweep/planted
instrument-sweep v1
check failure trust=missing
  defect damage=8 failure-path-exit-zero tests/fixtures/instrument-sweep/planted/failure.check.sh:6: a failed measurement exits 0, reporting an unreadable instrument as health [source: entries=$(wc -l < "$F") || exit 0]
  note unproven: check is not armed with a matching trust binding (trust=missing)
  result failure DEFECT (highest damage 8)

check identical trust=missing
  defect damage=10 identical-output tests/fixtures/instrument-sweep/planted/identical.check.sh:6: printed byte-identical stdout, stderr, and status for a healthy and a broken fact [source: printf 'queue: all clear for %s\n' "$(uname -s)"]
  note unproven: check is not armed with a matching trust binding (trust=missing)
  result identical DEFECT (highest damage 10)

check negative trust=missing
  defect damage=10 identical-output tests/fixtures/instrument-sweep/planted/negative.check.sh:7: printed byte-identical stdout, stderr, and status for a healthy and a broken fact [source: echo "result file looks good"]
  defect damage=8 discarded-negative-assertion tests/fixtures/instrument-sweep/planted/negative.check.sh:6: status discarded by a later command so the check cannot fail here [source: [ ! -s "$F" ]]
  note unproven: check is not armed with a matching trust binding (trust=missing)
  result negative DEFECT (highest damage 10)

check orphan trust=missing
  defect damage=10 identical-output tests/fixtures/instrument-sweep/planted/orphan.check.sh:7: printed no output and the same status for a healthy and a broken fact [source:   echo "orphan marker is present"]
  defect damage=6 orphan-marker tests/fixtures/instrument-sweep/planted/orphan.check.sh:6: reads marker .instrument-sweep-orphan-marker, which nothing in the scanned writer corpus (state checks plus bin) writes [source: if [ -s "$M" ]; then]
  note unproven: check is not armed with a matching trust binding (trust=missing)
  result orphan DEFECT (highest damage 10)

check rate trust=missing
  defect damage=5 rate-without-denominator tests/fixtures/instrument-sweep/planted/rate.check.sh:8: divides by total with no zero guard on total [source: pct=$((errors * 100 / total))]
  note unproven: check is not armed with a matching trust binding (trust=missing)
  result rate DEFECT (highest damage 5)

check stale trust=missing
  defect damage=10 identical-output tests/fixtures/instrument-sweep/planted/stale.check.sh:10: printed no output and the same status for a healthy and a broken fact [source:   echo "instrument has not reported recently"]
  defect damage=7 stale-reading tests/fixtures/instrument-sweep/planted/stale.check.sh:8: reads the mtime of .instrument-sweep-beat which this check writes itself instead of the fact it measures [source: last=$(stat -c %Y "$M")]
  note unproven: check is not armed with a matching trust binding (trust=missing)
  result stale DEFECT (highest damage 10)

check vacuous trust=missing
  defect damage=10 identical-output tests/fixtures/instrument-sweep/planted/vacuous.check.sh:8: printed byte-identical stdout, stderr, and status for a healthy and a broken fact [source:   echo "build: failures recorded in the log"]
  defect damage=9 vacuous-comparison tests/fixtures/instrument-sweep/planted/vacuous.check.sh:7: -n/-z over count, which is assigned a command that always prints a number [source: if [ -n "$count" ]; then]
  note unproven: check is not armed with a matching trust binding (trust=missing)
  result vacuous DEFECT (highest damage 10)

defect ranking (damage desc, then check id)
 1. damage=10 identical identical-output tests/fixtures/instrument-sweep/planted/identical.check.sh:6
 2. damage=10 negative identical-output tests/fixtures/instrument-sweep/planted/negative.check.sh:7
 3. damage=10 orphan identical-output tests/fixtures/instrument-sweep/planted/orphan.check.sh:7
 4. damage=10 stale identical-output tests/fixtures/instrument-sweep/planted/stale.check.sh:10
 5. damage=10 vacuous identical-output tests/fixtures/instrument-sweep/planted/vacuous.check.sh:8
 6. damage=9 vacuous vacuous-comparison tests/fixtures/instrument-sweep/planted/vacuous.check.sh:7
 7. damage=8 failure failure-path-exit-zero tests/fixtures/instrument-sweep/planted/failure.check.sh:6
 8. damage=8 negative discarded-negative-assertion tests/fixtures/instrument-sweep/planted/negative.check.sh:6
 9. damage=7 stale stale-reading tests/fixtures/instrument-sweep/planted/stale.check.sh:8
10. damage=6 orphan orphan-marker tests/fixtures/instrument-sweep/planted/orphan.check.sh:6
11. damage=5 rate rate-without-denominator tests/fixtures/instrument-sweep/planted/rate.check.sh:8

summary: checks=7 defect=7 unproven=0 proven=0 findings=11
```

Seven checks, seven defects, one per class, each at its own line.
Every finding ends with the exact source line that produced it, so a DEFECT carries its class, file:line, and snippet together.
The extra four findings are the identical-output class firing on fixtures that also behave identically when probed, which is the sweep doing its job twice rather than a misfire.

## Fixing every fixture silences the sweep

`bin/fm-instrument-sweep.sh --state tests/fixtures/instrument-sweep/fixed --probe-dir tests/fixtures/instrument-sweep/fixed`

```console
$ bin/fm-instrument-sweep.sh --state tests/fixtures/instrument-sweep/fixed --probe-dir tests/fixtures/instrument-sweep/fixed
instrument-sweep v1
check failure trust=missing
  note unproven: check is not armed with a matching trust binding (trust=missing)
  result failure PROVEN-DISTINGUISHING (differential probe produced different output for a healthy and a broken fact)

check identical trust=missing
  note unproven: check is not armed with a matching trust binding (trust=missing)
  result identical PROVEN-DISTINGUISHING (differential probe produced different output for a healthy and a broken fact)

check negative trust=missing
  note unproven: check is not armed with a matching trust binding (trust=missing)
  result negative PROVEN-DISTINGUISHING (differential probe produced different output for a healthy and a broken fact)

check orphan trust=missing
  note unproven: check is not armed with a matching trust binding (trust=missing)
  result orphan PROVEN-DISTINGUISHING (differential probe produced different output for a healthy and a broken fact)

check rate trust=missing
  note unproven: check is not armed with a matching trust binding (trust=missing)
  result rate PROVEN-DISTINGUISHING (differential probe produced different output for a healthy and a broken fact)

check stale trust=missing
  note unproven: check is not armed with a matching trust binding (trust=missing)
  result stale PROVEN-DISTINGUISHING (differential probe produced different output for a healthy and a broken fact)

check vacuous trust=missing
  note unproven: check is not armed with a matching trust binding (trust=missing)
  result vacuous PROVEN-DISTINGUISHING (differential probe produced different output for a healthy and a broken fact)

defect ranking (damage desc, then check id)
none

summary: checks=7 defect=0 unproven=0 proven=7 findings=0
```

## Live-state ranked report

Run from the live home checkout with this branch's binary.
The sweep reads the live checks and the live writers statically; it never executes a live check, and it writes only under `TMPDIR`.

`bin/fm-instrument-sweep.sh --state /home/aaron/Projects/firstmate/state`

The live home is a moving target: checks are registered and retired while fleet work runs, so the numbers below are a snapshot, not a fixed figure.
At this snapshot the corpus held 79 registered checks and the run reported 36 DEFECT, 43 UNPROVEN, 0 PROVEN.
No allowlist was applied, and every UNPROVEN entry states its own reason in the full output.

```console
$ bin/fm-instrument-sweep.sh --state /home/aaron/Projects/firstmate/state | tail -3
90. damage=6 pa-sweeper-live orphan-marker /home/aaron/Projects/firstmate/state/pa-sweeper-live.check.sh:16
91. damage=6 train-lines orphan-marker /home/aaron/Projects/firstmate/state/train-lines.check.sh:5

summary: checks=79 defect=36 unproven=43 proven=0 findings=91
```

The ranking is dominated by one defect instance replicated across fleet checks, which is the finding that matters most: the shape is a forge or remote read whose failure exits 0.

| Class | Findings | Where |
| --- | --- | --- |
| `failure-path-exit-zero` | 88 | 75 of them are the same three lines (65, 104, 105) copied into 25 PR-poll checks; the rest are the ssh watch family (5, 7), `jan-watch` (6, 8), `paid-sla-age` (5), `backlog-sentinel` (4), `terms-1728` (4), `decider` (35, 37) |
| `vacuous-comparison` | 1 | `box-forkbomb-guard` (22): `[ -n "$procs" ]` over `wc -l` output, which is never empty |
| `orphan-marker` | 2 | `pa-sweeper-live` (16), `train-lines` (5); both state that the writer lives in a project clone outside the scanned corpus |

## Highest-damage follow-up work

The highest-damage class is `vacuous-comparison` at damage 9 (`box-forkbomb-guard`), because a guard that cannot fail is silent in exactly the case it exists for.
At damage 8, the three-line forge template (`state=$(gh pr view ...) || exit 0`, `raw=$(glab mr view ...) || exit 0`, `state=$(printf ... | sed -n ...) || exit 0`) is one shared defect in 25 checks: a forge read that fails is reported as no merge.
The ssh watch family (`artem-watch`, `artem-cto-watch`, `jan-watch`, `nick-watch`) turns an unreachable host into silence the same way, and `paid-sla-age`, `backlog-sentinel`, `terms-1728`, and `decider` do it to a Prometheus query, an ssh `cat`, a `gh pr checks` read, and a scanner invocation.
The two `orphan-marker` findings at damage 6 are `pa-sweeper-live` and `train-lines`, whose marker is written outside the scanned writer corpus, so that finding is a question for their owner rather than a proven dead marker.
Clearing these is follow-up work, not part of this task.

## The suite holds both directions

`bin/fm-test-run.sh tests/fm-instrument-sweep.test.sh`

```console
$ bin/fm-test-run.sh tests/fm-instrument-sweep.test.sh | tail -3
ok - a divisor bound to a nonzero literal is not a rate defect
ok - only a stderr-only failure branch that exits 0 counts as silence
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=13976
```

The suite also proves the safety and honesty properties the sweep would otherwise only claim: a registered corpus keeps its trust binding and its directory listing unchanged across a run, an undeclared probe directory is refused with exit 2 so a live check is never executed, probe evidence does not leak from one check to the next, every finding carries its exact source line, and a check with no distinguishing scenario is reported `UNPROVEN` with its reason rather than passed.
Each of those assertions arms the corpus it writes: an unarmed corpus is only ever `UNPROVEN`, so a "no findings" assertion over it would hold no matter what the detectors do.
