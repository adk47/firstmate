# Order #7: the doc_class shadow gate

Captain's order 2026-11-15 15:2xZ, #7 of 12. A read-only report. It changes no code, no gate, no
policy and no timer, and it sends nothing.

## Fixed before the read

This section was written and committed before `tools/paired_read.py` was run on node-8. The
commit that carries it has no result in it; the result is added by a later commit, so the git
history is the record of the order of operations.

**Threshold (the captain's, not the worker's): false-approve rate <= 1% on >= 200 paired
decisions.** It does not move after the read. A failing number gets no second threshold, no
smaller denominator and no re-cut population.

The three answers, and the only three:

| answer | when |
| --- | --- |
| **PASS** | >= 200 paired decisions and the false-approve rate is <= 1% |
| **CANNOT** | >= 200 paired decisions and the false-approve rate is > 1%. doc_class stays shadow. |
| **NOT MEASURED** | fewer than 200 paired decisions. The count is the answer. doc_class stays shadow. |

What each word in the order means here, fixed now:

- **doc_class** is the document-only approval class: `automations.document_small_track` in
  `policies/credit-approval-automation.json` (its `doc_class` block: evidence kind `doc_verified`,
  verdict version `dv-4`), implemented by `scripts/credit_review/doc_approve.py`.
- **doc_class's outcome** for a request is a verdict doc_class RECORDED in the decider's ledger
  (`/var/lib/hydra/credit-review/ledger.sqlite3`): a `doc_approval_events` row (`would_approve`
  or `approved` is an approve, `refused` is a refusal), a `doc_approvals` row or a
  `doc_approval_audit` row (an approve), or a `decisions` row with `evidence_kind = 'doc_verified'`
  whose decision is `approve` or `approve_partial` (an approve; any other decision is not a
  verdict and makes the read fail closed).
  A request doc_class ever recorded an approve for counts as an approve, whatever it recorded later.
- **The real outcome** is core's own status for the request at the time of the read, from the
  replica: `approved` or `rejected`, not deleted. Any other status is no outcome yet. Every
  `rejected` counts as a real refusal, duplicate closes included: no rejection is excused.
- **A paired decision** is a request that has both.
- **A false approve** is a paired decision where doc_class recorded an approve and the real
  outcome is `rejected`.

One rule, and only one: **PASS** needs >= 200 paired decisions and a false-approve rate (false
approves / paired decisions) <= 1%; **CANNOT** is the same count with a rate > 1%; fewer than
200 paired decisions is **NOT MEASURED**. The read prints the counts and the rate whatever the
answer is, so the rule can be read off the same table.

Change record, 2026-11-15: the rule committed in `02a88f8a5` also carried a stricter
worker-added minimum (>= 200 of the pairs a doc_class approve). It was removed after the read,
on review, because the order states one threshold. The answer is the same under both (0 paired
decisions is below 200 either way). The same review found `tools/paired_read.py` counted every
`decisions` row that was not a literal `approve` as a refusal, while the decider records a
per-role document approval as `approve_partial`; the tool now counts both as an approve and
stops on any other decision value. That edit cannot change this read: no document decision row
exists (0 rows).

### What was already known when this was fixed

Honest order of operations: before writing this section the worker had read the class's code and,
on node-8 at 15:38Z, the ledger's table row counts and the live policy, to find out where a
doc_class verdict is stored. Those reads showed `doc_approvals`, `doc_approval_events` and
`doc_approval_audit` at 0 rows, no `decisions` row of a document kind, the live policy at
`approved: false` with `doc_class.shadow: true`, and a freeze marker at
`/var/lib/hydra-credit-verify/doc-approve.frozen`. So the worker expected NOT MEASURED when it
wrote the rules above. The threshold and the 200-pair minimum are the captain's and predate
every read; no real outcome and no pairing had been read; and each definition above was chosen
in the direction that makes a pass harder, not easier.

### The read

`tools/paired_read.py`, piped to node-8's interpreter (nothing is copied to the host):

```
ssh root@<node-8> 'PYTHONDONTWRITEBYTECODE=1 nice -n 10 python3 -' < tools/paired_read.py > read.json
```

It opens the ledger `mode=ro` with `query_only`, asks the replica one `SELECT id, status`, and
prints counts only.

## Result

**NOT MEASURED. 0 paired decisions (0 of them a doc_class approve), against a minimum of 200.
No false-approve rate exists: 0 of 0 is not a rate. doc_class stays shadow.**

The rules above were committed at `02a88f8a5` (2026-11-15T15:53:34Z). The read ran on node-8
from 15:53:52Z to 16:02:59Z against deployed sha `be9e53e6e`; its whole output is `read.json`.
The query file's sha256 at the read was
`a5bf3d6c1f242eab781bdcc273303c9326b3e8e4a503d8f4fbe1a202c866a510`, the file as it ran at
commit `02a88f8a5`. The tool was edited after the read (the rule, the reason text, the
descriptive pass, the leftover second rate and the `approve_partial` classification removed or
fixed) and was NOT run again. `read.json` is
the output of that as-run tool with the descriptive block removed.

| | count |
| --- | --- |
| requests with a recorded doc_class verdict | 0 |
| ... `doc_approval_events` rows (any state) | 0 |
| ... `doc_approvals` rows | 0 |
| ... `doc_approval_audit` rows | 0 |
| ... `decisions` rows of a document kind (`doc_verified`, `doc%`, `dv%`) | 0 |
| requests core has decided (approved / rejected) | 5,380,319 / 180,602 |
| **paired decisions** | **0** |
| paired decisions doc_class approved | 0 |
| false approves | 0 |
| false-approve rate over paired decisions | none (0 / 0) |

The answer is the same under the rule as committed and as it now stands: both need 200 pairs
and there are none.

### Why there are no pairs

doc_class has never recorded a verdict, in shadow or otherwise, and as deployed it cannot:

- The class is dormant, not shadowing. The live registry has `document_small_track` at
  `approved: false`, and `decide.py` evaluates the document class only when
  `doc_class_active()` is true (`scripts/credit_review/decide.py:2950-2954`: "DORMANT until the
  captain's approval is on file for it: no store read, no log line, no row"). A shadow
  `would_approve` event is written only from inside that path.
- `doc_class.shadow: true` is read by no code. The only reference to the key outside the policy
  file is the assertion in `scripts/tests/test_doc_approve_policy.py:69`. Flipping it changes
  nothing the decider does; what arms the class is `approved`.
- So the number of pairs does not grow with time under the present deployment. A later read of
  this same query returns 0 again until something records the class's verdicts.
- The freeze marker `/var/lib/hydra-credit-verify/doc-approve.frozen` is present (dated
  2026-11-05 21:19). Its text names a request `filler-48`, which reads like a test fixture; who
  wrote it was not established. While it exists `gate_not_frozen` refuses every row.

### What this read did and did not touch

- No write to the ledger, the doc store, the proof store, core, `/opt/hydra` or any policy. The
  ledger was opened `mode=ro` with `query_only`. The interpreter read the query from stdin; no
  file was left on node-8 (the scratch log path the query sets for the deployed modules' error
  lines was never created).
- The fraud-lens account gate was not called, because it writes. That also means the stock
  `credit-review.py doc-approvals --dry-run`, documented as a 0-write pass, is not one on
  node-8 for any account the gate holds: each such call appends a hold line with a queued proof
  ask. This read found that in the gate's code and did not exercise it.
- The replica read returned 5,560,921 decided rows in one statement. The read overlapped the
  15:55Z `credit-ask-tick`, which exited at once on its STOP file.
- Nothing was sent, and `doc_class.shadow` was not changed.
