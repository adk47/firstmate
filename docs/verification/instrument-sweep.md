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

`bin/fm-instrument-sweep.sh --state state --writers bin`

The run below is the live `state/*.check.sh` set on 2026-11-08: 42 checks, 14 DEFECT, 28 UNPROVEN, 0 PROVEN.
No allowlist was applied, and the 28 UNPROVEN entries state their own reason in the full output.

```console
defect ranking (damage desc, then check id)
 1. damage=8 ai-dev-secrets-eso-a1 failure-path-exit-zero state/ai-dev-secrets-eso-a1.check.sh:104
 2. damage=8 ai-dev-secrets-eso-a1 failure-path-exit-zero state/ai-dev-secrets-eso-a1.check.sh:105
 3. damage=8 ai-dev-secrets-eso-a1 failure-path-exit-zero state/ai-dev-secrets-eso-a1.check.sh:65
 4. damage=8 artem-cto-watch failure-path-exit-zero state/artem-cto-watch.check.sh:5
 5. damage=8 artem-cto-watch failure-path-exit-zero state/artem-cto-watch.check.sh:7
 6. damage=8 artem-watch failure-path-exit-zero state/artem-watch.check.sh:5
 7. damage=8 artem-watch failure-path-exit-zero state/artem-watch.check.sh:7
 8. damage=8 backlog-sentinel failure-path-exit-zero state/backlog-sentinel.check.sh:4
 9. damage=8 captain-requests-sweep failure-path-exit-zero state/captain-requests-sweep.check.sh:17
10. damage=8 churn-save-pause-offer-c1 failure-path-exit-zero state/churn-save-pause-offer-c1.check.sh:16
11. damage=8 factory-autonomy-fable-a1 failure-path-exit-zero state/factory-autonomy-fable-a1.check.sh:104
12. damage=8 factory-autonomy-fable-a1 failure-path-exit-zero state/factory-autonomy-fable-a1.check.sh:105
13. damage=8 factory-autonomy-fable-a1 failure-path-exit-zero state/factory-autonomy-fable-a1.check.sh:65
14. damage=8 jan-watch failure-path-exit-zero state/jan-watch.check.sh:6
15. damage=8 jan-watch failure-path-exit-zero state/jan-watch.check.sh:8
16. damage=8 nick-watch failure-path-exit-zero state/nick-watch.check.sh:5
17. damage=8 nick-watch failure-path-exit-zero state/nick-watch.check.sh:7
18. damage=8 paid-sla-age failure-path-exit-zero state/paid-sla-age.check.sh:5
19. damage=8 plaque-email-pack-m3 failure-path-exit-zero state/plaque-email-pack-m3.check.sh:104
20. damage=8 plaque-email-pack-m3 failure-path-exit-zero state/plaque-email-pack-m3.check.sh:105
21. damage=8 plaque-email-pack-m3 failure-path-exit-zero state/plaque-email-pack-m3.check.sh:65
22. damage=8 terms-1728 failure-path-exit-zero state/terms-1728.check.sh:4
23. damage=6 pa-sweeper-live orphan-marker state/pa-sweeper-live.check.sh:16
24. damage=6 train-lines orphan-marker state/train-lines.check.sh:5

summary: checks=42 defect=14 unproven=28 proven=0 findings=24
```

## Highest-damage follow-up work

The top of the ranking is the failure-path class at damage 8.
Six remote or API watchers exit 0 when their measurement fails, so an unreachable monitor reads as healthy: `ai-dev-secrets-eso-a1`, `artem-cto-watch`, `artem-watch`, `backlog-sentinel`, `jan-watch`, and `nick-watch`.
The same pattern recurs in `factory-autonomy-fable-a1` and `plaque-email-pack-m3` at lines 65 and 104-105, and in `paid-sla-age`, `terms-1728`, `captain-requests-sweep`, and `churn-save-pause-offer-c1` as error branches that exit 0.
The two orphan markers at damage 6 are `pa-sweeper-live` and `train-lines`.
Clearing these is follow-up work, not part of this task.

## The suite holds both directions

`bin/fm-test-run.sh tests/fm-instrument-sweep.test.sh`

```console
$ bin/fm-test-run.sh tests/fm-instrument-sweep.test.sh | tail -3
ok - a zero-guarded rate is not reported as a denominator defect
ok - identical-output falls back to the output statement, not line 1
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=17954
```

The suite also proves the safety and honesty properties the sweep would otherwise only claim: a registered corpus keeps its trust binding and its directory listing unchanged across a run, an undeclared probe directory is refused with exit 2 so a live check is never executed, probe evidence does not leak from one check to the next, every finding carries its exact source line, and a check with no distinguishing scenario is reported `UNPROVEN` with its reason rather than passed.
