# Arming the document decision step: what the recorded decision reaches, and where it stops

Read 2026-11-13 14:09-14:20Z against this branch and node-8 (deployed `c0f06f8f`). Nothing was armed, no
registry row was changed, no file on the host was moved.

The decision (firstmate inbox 001, 13:59Z): flip `document_small_track` to `approved: true`, move
`doc-approve.frozen` aside, arm `doc_approve.py` for credits and `claim-doc-ladder.py` for claims, sample 10% of
each run. Constraint in the same message: no guard loosened. Stop condition in the same message: a refusal that
needs a guard design change.

**That stop condition is met before core is reached.** The registry flip and the freeze file are two of six
switches. The other four are below; the third is hydra's own write gate, and changing it is a guard design change.

## The six switches between a verified document and a core write

| # | switch | where | state | covered by the decision |
| --- | --- | --- | --- | --- |
| 1 | class registry row | `policies/credit-approval-automation.json` `document_small_track` | `approved: false` | yes |
| 2 | freeze | `/var/lib/hydra-credit-verify/doc-approve.frozen` (test fixture text, 2026-11-05) | present | yes |
| 3 | hydra write gate | `muso-admin-api.sh` `is_credit_trust_decide_approval` (both copies) | refuses | no |
| 4 | approve arm | `policies/credit-trust-decide.json` `approve_arm` (`decide.approve_arm_off`) | `false` | no |
| 5 | an apply run | cron `credit-trust-decide-15m` runs `decide --mode judge` | no apply run exists | in part ("arm") |
| 6 | request status | the gate and the PUT carry `expectedStatus: unverified` | fixed | no |

### 3. The write gate refuses every document approval

A document approval is written by `decide.admin_writer()` as the decider: requester
`credit-trust-decide@hydra-ops`, env `CREDIT_TRUST_DECIDE=1`, header `X-Credit-Automation-Id: credit-trust-decide`.
The gate re-reads the registry at the write boundary and requires
`.automations["credit-trust-decide"].approved == true`. That row is `approved: false`, and the document row's own
`status_note` says it "stays approved=false regardless". The gate has no predicate that reads
`document_small_track`.

So with switches 1, 2, 4 and 5 all on, every PUT is refused by hydra with
`credit_approve_gate: credit-trust-decide is not approved`, and `write_ids` releases the row.

Two ways through, and why neither was taken:

- **Flip `credit-trust-decide` to approved.** Then `decide.registry_approved()` is true, `doc_only` is false, and
  an apply run writes the whole decider approve arm, not documents only. That is a wider class than the one
  decided, and it is the arm Fable turned off (`[key=decider-support-arm]`).
- **Add a gate predicate for the document class.** A new approve path in the gate: its own env flag and registry
  re-check, one request id per body, and the id checked against a provisional `doc_approvals` row the caller does
  not control (the `verify_anchor.py` shape). Both wrapper copies, the bats suites, and the registry's
  `wrapper_predicate`. Whether core accepts it depends on the grant bound to the decider's automation id, which
  was not read.

The second is the one that loosens nothing. It is a gate change with review rounds of its own, not a row flip.

### 4. The approve arm is off by a separate ruling

`approve_arm: false` makes `decide` book every approve verdict as `held:approve_arm_disabled` and release the
document row before any PUT. Turning it on is a one-line policy change, and it reverses
`[key=decider-support-arm]`, which the decision does not cite. In a doc-only apply it affects document rows only.

### 6. Most of today's verified documents are out of reach by status

15 requests have a standing verified document (13:50Z). In core: 3 `unverified`, 8 `user_verification_needed`,
3 approved, 1 gone. The decider path writes `unverified -> approved` only, so 3 requests is the ceiling for a
first run, before the class's own gates (tier T0/T1, claimant, same release, caps).

## The arming measurement cannot be read

R22a's arming condition is the 0-write dry run, `credit-review.py doc-approvals --dry-run`. On node-8 at 14:10Z it
answers `unreadable`:

```
core could not be read for account ages (admin GET failed rc=2: muso-admin-api: refusing GET
/admin/credit-requests: page=102 (offset 20200 > 20000) with no profilesIds/trackId: deep unfiltered paging
```

It reads account ages by paging the admin list, which refuses past offset 20,000. The watchdog makes the same
measurement (`doc_measure.measure`), so an armed class would be reported blind. Nobody can say today how many
requests the class would approve. `--offline` (every row measured without the claimant's age) did not finish in
240 s; a 25-minute run was started at 14:15Z and writes `/root/proof-e1/doc-dry-run-offline.json` on node-8.

The fix is the one `scale_drain.py` already made: read the ages from the core replica, not the admin list.

## Claims: there is nothing to arm

`claim-doc-ladder.py` records an outcome and stops. No code approves a claim from it: no executor, no admin
route call, no gate predicate, no registry row. "Arm it the same way" means writing a new approval automation.

## What was not done, and why

- The registry row was not flipped. Flipped alone it changes what the judge cron and the watchdog report and
  moves no request; the row would read armed while the gate refuses every write.
- `doc-approve.frozen` was not moved. It blocks nothing while the class is off.
- No sampler was written: there are no decisions to sample.

## What would move requests

1. Read account ages from the replica so the dry run answers. Small, no guard touched.
2. The gate predicate for the document class, in its own PR.
3. Then the row flip, `approve_arm`, the freeze file and one supervised apply run, with the two requests the
   registry row names first.

Steps 1 and 2 are a new task. Step 3 is the decision already recorded.
