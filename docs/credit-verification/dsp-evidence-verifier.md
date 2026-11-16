# DSP evidence verifier (shadow)

> Captain 2026-10-28 01:5xZ: Fable stops ruling credits; the rules go into code, and the SYSTEM verifies
> credits "with lots of protection". Hard limit: **shadow only**. The verifier computes a verdict and
> logs it with its evidence. It never approves, declines, merges or messages anyone. Whether it ever acts
> is the captain's call, made on measured precision (verifier-eval-v1).

Code: `scripts/credit_verify/dspverify/` (rules `rules.py`, store `store.py`, runs `runner.py`, IDP hop
`capture.py` + `pod_driver.py`). CLI: `scripts/credit-dsp-verify.py`. Tests: `scripts/tests/test_dsp_verify.py`.

## Where it sits: a separate verification process (captain 03:4xZ)

Caroline is the front door only: she talks, looks things up, files, and hands off. Verification runs in its
**own process with its own identity**, never inside Caroline's process or tools.

| step | what runs it | where | what triggers it | writes |
|---|---|---|---|---|
| intake | Caroline `doc-intake`, `credit-proof.py file` (Intercom), email / in-app filers | edge gateway / node-8 crons | a user sends something | `proof_intake` |
| document reader + forensics + issuer/person checks | `credit-proof.py`, `credit-doc-verify.py run` | node-8 crons, moving to cluster jobs (hydra-cronjobs-t5) | schedule | proof store, `dv_*` |
| **DSP evidence (this)** | `credit-dsp-verify.py run` | node-8 / cluster job (hydra-cronjobs-t5), `kubectl exec` into an IDP `industry-proc-catalog-admin` pod for the capture | schedule (every 30-45 min: each run reads what the last one filed, then files the next batch) | `dsp-verify.sqlite` only |
| account gate | `/opt/firstmate/fraud-lens/account_gate.py check` (fraud-lens), via `credit_review/account_gate.py` | node-8 | called once per account per run | nothing |
| verdict + evidence | `rules.verify(packet)` | inside the job above | each packet | `dsp_verdicts` (append-only) |
| action | nothing yet | - | the captain's switch (`policies/credit-approval-automation.json`) | - |

This verifier is **not** in the approval registry because it has no apply mode at all. A consumer that turns
its verdicts into writes would be a new registered automation, `approved:false` until the captain's ref.

## The verdict

`rules.verify(packet)` is a pure function: no I/O, no clock, no model. It decides **per role** and then per
request. The packet fields are documented in the `rules.py` docstring.

### APPROVE (the only approving evidence: V1 by id, on BOTH DSPs, same run)
All of these must hold:
1. **Same-run Spotify AND Tidal anchor on the role.** Both fresh captures were requested by this run (IDP
   `helpers.fresh_capture`, instant priority), came back after the request (`captured_at > requested_at`),
   and credit the claimant's **linked raw id** (the contributor id already on the Muso profile) in the role
   family (`CREDITED / person_credited_in_role_family` with an id-credited pair). A **name** is never an anchor
   (d1 N1, d3 §1, captain 23:30Z). If Tidal was read per country, every country must credit by id.
2. **Account gate `allow`**, band not red (amber is allowed, with lower confidence). `hold`, `unknown`, a
   gate that did not run: no approval.
3. **Not big**: catalog track popularity known and < 60, every linked artist read and < 90, profile credit
   count known and < 200 (d1: two signals of different kinds are needed there, and this verifier has one
   kind). Any of them unknown = big.
4. **Not common**: other live catalog profiles with the same folded name are counted in the capture pod
   (the catalog `$name` text index, phrase search, exact folded compare). Any collision, a one-token name, or
   an unreadable count blocks.
5. **Not flagged**: each guard flag (`watchlist`, `deny_user`, `deny_profile`, `idp_hold`) is an explicit
   `false`; a missing or `null` flag is UNKNOWN and blocks. The deny lists and `policies/fraud-watchlist.json`
   are read by the job (missing file = fatal); the IDP credit-hold list (`IDP_CREDIT_HOLD_SUBMITTER_IDS` +
   `_FILE`) is read inside the capture pod, and a pod that carries neither reads UNKNOWN. Validator findings
   must be read (`verificationData.rule_risk_percent` present, else `validator_unknown` blocks), and no
   validator **fraud** rule fired (`reject_*` except the source rules). A risk-score decline
   (`risk_score_at_or_above_threshold`, `score:*`) is not a fraud rule (d3 §1.4, §7).
6. **Not a duplicate** of an approved request by the same account for this track and role families
   (then `DUPLICATE`, a no-op, never a rejection). The profile's approved requests are read in full; a failed
   or truncated read is `duplicate_unknown` and blocks approval.
7. Editorial roles (editing / compilation / assembly) only under popularity 30 (decide.py).

Only the anchored roles are named in `approve_roles`; the rest are `role_edit_roles` (the role edit comes
before any approval; a request is never approved whole on one good role, d3 §1).

### DECLINE (contradiction only)
Every claimed role is a **one-person role** (mix / master / remaster / immersive / remix families, bass,
drums; the captain's cardinality rule, d3 §1) where **both** complete, fresh Spotify and Tidal snapshots
show the claimant linked by id and absent, and both credit **the same one other person** in that role.
"The same person" is identity, never a name: each DSP credits exactly one other contributor id and one
catalog profile holds both of those raw ids, and neither snapshot carries an unresolved (name-only) credit in the
role family. Same name without that link, or any unresolved credit, is `one_person_identity_unproven`
(WAIT). This
is the build plan's C6 rule and doc-verify's `live_contradiction` (Fable Q3, 2026-10-27). A multi-person
role credited to others only is **NOT FOUND → WAIT**, never a decline (R-C2(3)). The approval guards do
not apply to a decline: it rests on evidence either way.

### WAIT (everything else), with a machine class and a `need`

| class | meaning | need |
|---|---|---|
| `capture_pending` | a capture is not back yet (re-read next run; closes after 90 min) | - |
| `link_mismatch` | the linked id is absent but the claimant's exact name is credited under another id | `fix_profile_link` |
| `needs_profile_link` | the name is credited, the profile has no contributor id on that DSP (the biggest class: d1 N1, d3 §2) | `link_profile` |
| `person_not_linked` | no contributor id on either DSP | `link_profile` |
| `dsp_conflict` | one DSP credits by id, the other is linked-and-absent (or Tidal countries disagree) | `link_check` |
| `single_dsp_anchor` | one DSP credits by id, the other has no recording / is unknown | `second_dsp_anchor` |
| `one_source_contradiction` | a one-person role contradicted on one DSP, the other has no recording | `document_for_this_track` |
| `one_person_identity_unproven` | the same name on both DSPs, but no catalog profile links the two contributor ids | `document_for_this_track` |
| `one_person_conflict` | one-person role, not one and the same other person on both DSPs | `document_for_this_track` |
| `others_only` / `nobody_in_role` / `absent_on_<dsp>` | not found | `document_for_this_track` |
| `no_recording` | no Spotify or Tidal recording on the catalog track | `document_for_this_track` |
| `anchored_but_blocked` | anchored, but a guard failed (gate, big, common, flagged, fraud rule) | `account_proof` / `second_signal` |
| `editorial_role` | anchored editorial role at popularity >= 30 | `org_or_label_letter` |
| `not_dsp_verifiable` | a role DSPs never carry (video, photo, management, A&R, legal, ...; d1 N13) | `org_or_label_letter` |
| `org_label_anchor` / `org_not_on_label_strings` / `org_string_missing` / `org_role_on_person_profile` | org lane: the org name vs the track's label / ℗ / © strings (distinctive tokens, order-free). Evidence only: approving on it is the captain's `declined-org-label-anchor-call` | varies |
| `no_fresh_capture` / `unknown` | nothing this run can stand on | - |

The `link_profile` / `fix_profile_link` classes feed the shadow profile-link proposals
([profile-link-proposals.md](profile-link-proposals.md)): a link is proposed only when it is unambiguous. An id held
by another profile goes to the merge lane. A mismatch goes to the tray and is never relinked.

UNKNOWN never approves and never declines (exhaustively tested in `UnknownNeverApproves`). Only a reading with an
explicit `state: CAPTURED` can anchor or contradict, and only `complete_snapshot: true` can contradict; a missing
field is UNKNOWN.

Confidence: 0.95 APPROVE with every role anchored (0.85 with a role edit, minus 0.1 on an amber account),
0.9 DECLINE and DUPLICATE, 0.6 anchored-but-blocked, 0.5 other WAITs. It ranks verdicts for review; the
eval measures whether it means anything.

## Running it (shadow)

```
python3 scripts/credit-dsp-verify.py run                 # verify open captures, then file the next batch
python3 scripts/credit-dsp-verify.py submit|verify        # the two halves
python3 scripts/credit-dsp-verify.py summary             # counts of the standing verdicts
python3 scripts/credit-dsp-verify.py export > v.jsonl    # standing verdict per request
python3 scripts/credit-dsp-verify.py verify-packets p.jsonl [--log]   # eval entry point, no network
```

- Store: `/var/lib/hydra-credit-verify/dsp-verify.sqlite` (`$CREDIT_DSP_VERIFY_STORE`). `dsp_verdicts` is
  append-only and shadow-only (triggers refuse UPDATE, DELETE and any `mode` other than `shadow`); the latest
  row per request under the current `VERSION` stands. Every row carries the full per-role, per-DSP evidence,
  the capture request id and the packet's sha256. JSON is never truncated: a field over 8 MB refuses the row
  (the capture stays open and the error is counted).
- Captures are read per (track, profile): one account claiming one track on two profiles gets each profile's
  own by-id reading.
- Kill switches: `/etc/hydra/credit-dsp-verify.disabled` or the shared `/etc/hydra/credit-verify.disabled`
  stop `submit`, `verify` and `run` before any read or capture.
- A capture closes only after every verdict of its read is persisted; a failed core re-read or packet leaves
  it open for the next run.
- Reversible: a verdict is a row, never an action.
- Core is read with GETs only (`credit_review/admin.py` refuses anything else). The only side effect outside
  the store is the capture itself: an instant-priority catalog capture, a raw refresh like any other.
- Order: paid first (the hourly paying-users export), then oldest. Paying status orders; it never decides.
- Needs on the host: `kubectl` with exec on `muso-prod` `industry-proc-catalog-admin` pods (as the Fable
  deciders' `dsp3.py` used on node-8 on 2026-10-27), the admin wrapper, the account gate. Env knobs:
  `CREDIT_DSP_KUBECTL`, `CREDIT_DSP_NAMESPACE`, `CREDIT_DSP_POD_PREFIX`, `CREDIT_DSP_EXEC_TIMEOUT_S`.

No cron ships in this PR: the job lands as a cluster CronJob with the other verification jobs
(hydra-cronjobs-t5), so it runs in its own process from day one.

## Measuring it (verifier-eval-v1)

The eval builds packets from labelled history and calls `rules.verify` (or `credit-dsp-verify.py
verify-packets`). It reads `verdict`, `approve_roles`, `decline_roles`, `reason_class`, `anchor` and
`confidence`. The bars the build plan set for C6: **0 false APPROVE**, DECLINE precision >= 95 %, capture
p95 < 90 min. Look at the `single_dsp_anchor` and `one_source_contradiction` classes separately: they are
what a looser rule would act on, so their labelled precision is what the captain needs to choose.

## Open points (flagged, not decided here)

- **One-source declines.** d3 §1 lets one DSP decline when the other has no recording (it ruled 331850 that
  way). The build plan C6 and doc-verify's Q3 ruling require both DSPs. This verifier follows the build plan
  and logs the d3 shape as `one_source_contradiction`. ~85 % of tracks have no Tidal raw (d3 §2), so this
  choice decides most of the decline recall.
- **Whole-request decline for role stuffing** (linked and absent from a complete snapshot that credits a full
  team on every claimed role, d3 §1): not coded. Those rows WAIT, with `role_stacking` in `signals`.
- **Tidal per country.** The IDP capture reads the Tidal album once; there is no per-country reading yet.
  The rules already require every country to agree when `countries` is present. Core's removal gate
  (#10765 / #10767) has the per-country read and is the place to source it from.
- **IDP hold list in the capture pod:** if the catalog-admin pods do not carry `IDP_CREDIT_HOLD_SUBMITTER_IDS`,
  every row reads `flags_unknown: idp_hold` and nothing is approve-eligible. The first shadow summary shows
  which; the fix is mounting the hold file there, or another read-only source for the list.
- **Not read yet:** watchlist email/name hashes (the job matches user and profile ids), D2 withdrawals,
  document evidence
  (doc-verify's `verified` is the second signal a consumer would combine with this verdict).
- One-person set: Recording Engineer (d1 only) is left out on purpose. A narrower set can only cost a decline.

## Anchor records for L12 approvals

For an approve tray, `credit-dsp-verify.py anchors --tray <tray.json>` builds the server-side anchor
record per row from the verifier's own verdict (Fable `l12-approvals-core` = A):
[`dsp-anchor-record.md`](./dsp-anchor-record.md). That subcommand writes nothing to core; built records are
posted by the `credit-anchors-push` cron (`scripts/credit-anchors-push.py --pending --apply`).
