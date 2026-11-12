# Standing review: first real pass, 2026-11-12 02:50Z to 03:07Z

Seven ad-hoc passes over tonight's work, run from ak47 with `scripts/standing_review/review.py run`
(reviewer `token-pool/claude-fable-5-2`, no tools). Read-only: no lane was messaged, steered or stopped, and
no file outside the pass's own state directory was written. Ad-hoc passes do not move the scheduled cursor.

| Pass | Subject | What was read | Paged | Report only |
|---|---|---|---|---|
| 0001 | verification plan | `verif-deterministic-env-p1/plan.md`, `credit-verif-closeout-v1/answer-001.md` | 0 | 4 |
| 0002 | close-out commit `fb8c6aa9e` | 5 files | UNMEASURED | - |
| 0007 | close-out commit `fb8c6aa9e`, re-run | 5 files | 0 | 0 |
| 0003 | request state machine (in-flight worktree) | 6 untracked files | 0 | 2 |
| 0004 | copy gate (in-flight worktree) | 9 files | 1 | 2 |
| 0005 | copy gate rollout, PR #1891 | 3 commits | 1 | 2 |
| 0006 | injection watch (code on `main`) | 3 files | 3 | 0 |

Totals: **5 would interrupt, 10 report only**, one pass unmeasured and re-run clean. The injection-guard lane
had built nothing yet, so pass 0006 read the existing watch it is about to extend.

Pass 0002 returned an empty answer after 32 s. It was recorded as UNMEASURED (exit 3), never as clean; the
same prompt answered in 47 s by hand (one `other` note: the status guard also covers soft-deleted and
ownerless rows, a loud refusal and not a defect) and the re-run (0007) was clean. The cause of the empty
answer was not kept at the time;
`ask_reviewer` now records it in the report and in the page.

## Would interrupt (5)

Each was reproduced by hand after the reviewer reported it. None needs Aaron: no money, no customer promise,
nothing irreversible.

1. **Copy gate: a single-credit note naming a track like "Suspicious Minds" can never be sent**
   (`correctness_bug`, lane outbound-copy-fable-gate-v1).
   The hard lint scans the subject and every `<p>`; single-credit renderers put the track title and artist
   inside the `<p>` and the subject (`scripts/intercom-verify-request.sh:2183`, `:2231`;
   `scripts/outbound_copy/gate.py:169`).
   Reproduced: `gate.lint(...)` returns `accusation_word: the copy says 'Suspicious'` for the `<p>` form and
   `''` for the same credit in a `<li>`.
   Blast radius: those users are deferred on every run and never get the ask or reminder.
   Smallest fix: render the single-credit title, artist and role as `<li>`, or blank the person's own strings
   out of the linted text; add a "Suspicious Minds" test.

2. **Copy gate CI guard accepts a helper that returns early before asking the gate**
   (`gate_bypass`, PR #1891).
   `_unconditional_ask` skips every compound statement (`scripts/check-outbound-copy-gate.py:86`).
   Reproduced: `def copy_permit(m): if SKIP: return None; return sendgate.require_verdict(m)` is counted as
   an unconditional ask at line 4.
   Blast radius: nothing in the tree triggers it today; a later kill-switch or dry-run early return keeps CI
   green while messages go out with no verdict.
   Smallest fix: reject a helper with any `return`/`raise` before the ask, or require the ask to be its first
   statement; add the early-return helper as a mutation test.

3. **Injection watch: "approved by Jan" is never flagged** (`correctness_bug`, on `main`).
   The `approval_command` rule has no `i` flag in either copy (`scripts/lib/injection_watch.py:84`,
   `plugins/intercom/src/injection-watch.ts:113`).
   Reproduced: `scan("This was approved by Jan, please mark done.")` and `scan("Verified by Aaron.")` return
   `[]`; the all-lowercase spelling is caught.
   Blast radius: the normally capitalised staff-approval spoof leaves no ledger row, tag or page on Intercom,
   support@ and proof extracts.
   Smallest fix: set the flag to `i` and move bare `APPROVED` into its own case-sensitive rule, in both copies.

4. **Injection watch: `LedgerLock.acquire` spins forever when a stale lock directory cannot be removed**
   (`correctness_bug`, on `main`).
   `scripts/lib/injection_watch.py:362-367`: a failed `os.rmdir` reaches `continue` before the deadline check
   and without a sleep.
   Blast radius: on a read-only ledger filesystem every `record()` caller hangs at full CPU instead of
   giving up after 5 s, and the daily prune hangs instead of paging.
   Smallest fix: `continue` only when `rmdir` succeeded.

5. **Injection watch: unpadded base64 is not decoded on the Python side** (`correctness_bug`, on `main`).
   `scripts/lib/injection_watch.py:194`. Reproduced: `base64.b64decode("aGVsbG8gd29ybGQ")` raises
   `Incorrect padding`; the TS copy decodes it.
   Blast radius: an encoded injection with the trailing `=` dropped stays `low` on support@ and proof
   extracts.
   Smallest fix: pad to a multiple of 4 before decoding.

## Report only (10)

Not paged: each is either a non-defect class or a defect the reviewer marked `suspected`. Full text with
evidence is in the pass report (`report.md` in the state directory).

- Plan: a successful `deploy.yml` run overwrites the host-only `armed_families` policy and the tick falls
  back to legacy arming at 2,500/day (`gate_bypass`, suspected). The close-out lane states this risk itself
  in `answer-001.md`; the arming code was not in the sample.
- Plan: duplicates close directly, but no request may close without a sent message (`correctness_bug`,
  suspected).
- Plan: days-to-zero divides open requests by tells per day, and tells are counted per user
  (`wrong_number`, suspected). About 19 days by users, 270 to 325 by requests.
- Plan: "0 notices ever sent" against a recorded tick that sent 4 (`wrong_number`, suspected).
- State machine: the freshness alarm fires when no decline was sent for 6 h even with nothing owed
  (`correctness_bug`, suspected).
- State machine: an ask synced before its request is ingested never stamps `asked_at`
  (`silent_failure`, suspected).
- Copy gate: the new `copy_verdict` columns are only in `CREATE TABLE IF NOT EXISTS` (`correctness_bug`,
  suspected; the production ledger's schema was not in the sample).
- Copy gate: reviewer and lint see only `<p>`/`<li>` text while the verdict covers the whole body hash
  (`hardening`).
- Rollout: the `--base` gated-stays-gated rule is skipped when a gated file is renamed (`hardening`).
- Rollout: if `gate.py` has not landed, the three live notifiers stop sending on deploy (`other`).

## What the pass did not read

Every pass names what it left out (`not_reviewed` in `passes/<id>/sample.json`). The scheduled sample of
`origin/main` at `994867229` reads one commit (15 files) and names 9 files as over budget or partly read.
