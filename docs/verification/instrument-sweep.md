# Instrument sweep

Repeatable evidence for `bin/fm-instrument-sweep.sh`, the sweep that finds checks whose output does not depend on their input.
The command's header owns the defect classes, damage weights, TSV schema, and probe contract; this record owns the proof that the sweep can report dirty at all.

The only test that matters for a defect finder is that it names a planted defect, so the proof runs against `tests/fixtures/instrument-sweep/` rather than against the current tree.
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
  defect damage=8 failure-path-exit-zero tests/fixtures/instrument-sweep/planted/failure.check.sh:6: a failed measurement exits 0, reporting an unreadable instrument as health
  note unproven: check is not armed with a matching trust binding (trust=missing)
  result failure DEFECT (highest damage 8)

check identical trust=missing
  defect damage=10 identical-output tests/fixtures/instrument-sweep/planted/identical.check.sh:6: printed byte-identical stdout, stderr, and status for a healthy and a broken fact
  note unproven: check is not armed with a matching trust binding (trust=missing)
  result identical DEFECT (highest damage 10)

check negative trust=missing
  defect damage=10 identical-output tests/fixtures/instrument-sweep/planted/negative.check.sh:7: printed byte-identical stdout, stderr, and status for a healthy and a broken fact
  defect damage=8 discarded-negative-assertion tests/fixtures/instrument-sweep/planted/negative.check.sh:6: status discarded by a later command so the check cannot fail here
  note unproven: check is not armed with a matching trust binding (trust=missing)
  result negative DEFECT (highest damage 10)

check orphan trust=missing
  defect damage=10 identical-output tests/fixtures/instrument-sweep/planted/orphan.check.sh:1: printed no output and the same status for a healthy and a broken fact
  defect damage=6 orphan-marker tests/fixtures/instrument-sweep/planted/orphan.check.sh:6: reads marker .instrument-sweep-orphan-marker, which nothing in the scanned writer corpus (state checks plus bin) writes
  note unproven: check is not armed with a matching trust binding (trust=missing)
  result orphan DEFECT (highest damage 10)

check rate trust=missing
  defect damage=5 rate-without-denominator tests/fixtures/instrument-sweep/planted/rate.check.sh:8: divides by total with no zero guard on total
  note unproven: check is not armed with a matching trust binding (trust=missing)
  result rate DEFECT (highest damage 5)

check stale trust=missing
  defect damage=10 identical-output tests/fixtures/instrument-sweep/planted/stale.check.sh:1: printed no output and the same status for a healthy and a broken fact
  defect damage=7 stale-reading tests/fixtures/instrument-sweep/planted/stale.check.sh:8: reads the mtime of .instrument-sweep-beat which this check writes itself instead of the fact it measures
  note unproven: check is not armed with a matching trust binding (trust=missing)
  result stale DEFECT (highest damage 10)

check vacuous trust=missing
  defect damage=10 identical-output tests/fixtures/instrument-sweep/planted/vacuous.check.sh:8: printed byte-identical stdout, stderr, and status for a healthy and a broken fact
  defect damage=9 vacuous-comparison tests/fixtures/instrument-sweep/planted/vacuous.check.sh:7: -n/-z over count, which is assigned a command that always prints a number
  note unproven: check is not armed with a matching trust binding (trust=missing)
  result vacuous DEFECT (highest damage 10)

defect ranking (damage desc, then check id)
 1. damage=10 identical identical-output tests/fixtures/instrument-sweep/planted/identical.check.sh:6
 2. damage=10 negative identical-output tests/fixtures/instrument-sweep/planted/negative.check.sh:7
 3. damage=10 orphan identical-output tests/fixtures/instrument-sweep/planted/orphan.check.sh:1
 4. damage=10 stale identical-output tests/fixtures/instrument-sweep/planted/stale.check.sh:1
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

## The suite holds both directions

`bin/fm-test-run.sh tests/fm-instrument-sweep.test.sh`

```console
$ bin/fm-test-run.sh tests/fm-instrument-sweep.test.sh | tail -3
ok - --fail-on-defect follows the findings, not the corpus
ok - a probe that cannot set up reports UNPROVEN, never a pass
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=14258
```

The suite also proves the safety and honesty properties the sweep would otherwise only claim: a registered corpus keeps its trust binding and its directory listing unchanged across a run, an undeclared probe directory is refused with exit 2 so a live check is never executed, and a check with no distinguishing scenario is reported `UNPROVEN` with its reason rather than passed.
