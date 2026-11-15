# DSP anchor record (`dsp-anchor/1`): the server-side evidence behind an L12 approval

> Fable ruling `l12-approvals-core` = **option A**, with B's table as the evidence record where no
> `credit_proofs` row fits (2026-10-28 22:30Z). Core's principle stands: every input to an approval is a
> column the server wrote, never a value the caller asserts. "Approve" must never be faster than "prove".

## Who writes what

| step | who | where | writes |
|---|---|---|---|
| 1. capture | `credit-dsp-verify.py submit --tray <tray.json>` (own job, credit-decider identity) | node-8 / cluster job; `kubectl exec` into an IDP `industry-proc-catalog-admin` pod | an instant-priority Spotify + Tidal capture per tray row, tagged with OUR request id |
| 2. verdict | `credit-dsp-verify.py verify` | same job | `dsp_verdicts`: verdict + complete packet (shadow store) |
| 3. anchor record | `credit-dsp-verify.py anchors --tray <tray.json>` | same job | `dsp_anchors` (local, append-only); writes nothing to core |
| 4. upload | `scripts/credit-anchors-push.py --tray <tray.json> [--apply]` | manual, per approve tray | core's `credit_anchor_records` (`POST /admin/credit-anchors`), one row per role and source (`credit_review/anchor_upload.py` owns the conversion) |
| 5. approve | the L12 executor (credit-refresh-t01b, `credit-fable-execute.py`) | its own job | approves ONLY through the proof-backed path that reads the server-written record |

The record is built from the verifier's **own** standing verdict and packet for that request, and only from a
verdict this job produced in a `verify` run from a capture it filed for that request (`latest_captured_for`).
Verdicts logged from supplied packets (`verify-packets --log`, eval) never anchor. The tray only
says which requests to look at. The ruling id is carried as `metadata.ruling_id` and is never the
admitting value. Before minting a record, the builder re-runs `rules.verify(packet)` (`anchor.py`), so a
stored verdict that has drifted from its packet cannot produce one.

## What the executor's approve step admits

Step 5 writes nothing while `fable-decider.apply_enabled` is false in `policies/credit-approval-automation.json`
(it ships false). With the switch on, the same entry's `apply_filter` block decides which rows may be approved,
and `fable_executor.registry_apply_filter` holds its floor in code: a registry edit can tighten the block (a lower
`per_run_cap`, more excluded bands) and a missing, malformed or weaker block refuses every row
(`apply_filter_invalid`).

| key | what it enforces | refusal |
|---|---|---|
| `outcome: credit-anchored-approve` | the row's rule is `C4:anchored/v1` and it cites a `dsp_verdicts` row | `outcome_not_credit_anchored_approve` |
| `exclude_bands` (always holds `none`) | a request with no `band_hint` is never approved | `band_excluded:none`, `band_unmeasured` |
| `exclude_conflict_rule_failures` | another user's approved or awaiting-verification request on the same track with a credit in common | `conflict_rule_failure`, `conflict_rule_unmeasured` |
| `exclude_self_duplicate_groups` | the same user's other open request for the same track and the same credits | `self_duplicate_group`, `self_duplicate_unmeasured` |
| `per_run_cap` (1 to 50; ships 1) | the most approves one run may write | the run stops: `per-run cap N reached` |
| `batch_id_required` | `--apply` on an approve tray needs `--batch-id`; every audit line of the run carries it | the run stops before any write |

The three exclusions are read from the core replica for exactly the rows about to be written
(`fable_executor.approve_filter_facts`), again at the wrapper boundary (`verify_batch`), and a read that fails or
answers for fewer rows refuses them (`apply_filter_unmeasured`). After each PUT the ids core names in `updatedIds`
must equal the ids sent, or the run stops there. `credit-fable-execute.py --batch-rows ID` lists the request ids
the audit shows written under a batch id; the executor has no revert, so returning a batch is a person's PUT of
that list.

A cap only slows how fast wrong approvals are written; the filter is what keeps the known-wrong classes out.
The filter does not arm anything: `doc_class.shadow` and the switch are separate decisions.

## Record (JSON, schema `dsp-anchor/1`)

Common fields:

| field | meaning |
|---|---|
| `schema`, `kind` | `dsp-anchor/1`; `dsp_anchor` (person credit) or `dsp_label_line` (org credit) |
| `request_id`, `user_id`, `profile_id`, `track_id` | the credit request it anchors |
| `isrcs` | ISRCs the **catalog** holds for the track's Spotify/Tidal recordings (read by the capture job, never the request's metadata). The core side should bind the record to the row by ISRC + role |
| `roles` | the roles the evidence supports. `dsp_anchor`: roles BOTH DSPs credit to the claimant's linked id. Anything else the tray lists is a role edit before approval (`role_edit_roles`) |
| `capture_request_id`, `capture_requested_at`, `capture_read_at` | the IDP `helpers.fresh_capture` request this run filed |
| `verifier` | `{version, verdict, reason_class, reason, confidence, blockers}` |
| `gate`, `flags`, `popularity` | account gate answer, guard flags, catalog popularity at verdict time |
| `written_by` | `credit-dsp-verify (credit-decider)` |
| `built_at` | when the record was built |
| `metadata.ruling_id` | the tray's Fable ruling id (metadata only) |
| `record_sha256` | sha256 of the canonical JSON (sorted keys, no whitespace) without this field |

`dsp_anchor` only:

| field | meaning |
|---|---|
| `both_read` | always `true` (no record otherwise) |
| `captured_at` | latest `captured_at` across the sources |
| `role_evidence[role].sources[]` | per DSP: `source`, `state` (`CAPTURED`), `helper_verdict`, `helper_reason`, `complete_snapshot`, `captured_at`, `capture_ids[]`, `recordings[]`, and `role_holders[]` = every contributor the fresh capture credits in that role family `{name, credit, is_claimant_linked_id, raw_id, catalog_profile_id}` |

`dsp_label_line` only:

| field | meaning |
|---|---|
| `org_name` | the org profile's name |
| `label_lines[]` | the catalog's DSP ℗ / © / label strings that contain the org's distinctive tokens `{source, release_id, kind, string}` |
| `label_lines_read_at`, `label_lines_fresh` | catalog read time; `false` because the line is a catalog read, not a same-run capture (the IDP receipt carries credits only) |
| `both_read` | `false` |

## When no record is built (logged as `refused` with the reason)

- The verdict is not APPROVE (`dsp_anchor`), or not `org_label_anchor` (`dsp_label_line`).
- The stored verdict disagrees with its packet.
- The capture was requested more than 24 h before the record is built.
- The catalog holds no ISRC for the track.
- `dsp_label_line` only: the profile is not an organization; the account holds no processed, live claim
  on it (Trino `postgresql_core.public.claiming`; unknown = no record); any request-level guard is
  blocking (gate, big, common, flagged, validator, duplicate); or the org name is not on the catalog's
  DSP label lines.

## The core side (for credit-refresh-t01b)

**Current:** core carries `credit_anchor_records` and `POST /admin/credit-anchors` (core #11010/#11011), the
approve scope reads them (`credit_review/policy.py` — L12 approvals are anchor-backed rows only), and
`scripts/credit-anchors-push.py` is what puts a built record there. The conversion to core's per-(role, source)
shape lives in `scripts/credit_review/anchor_upload.py::to_core_records`; core re-decides the claimant match and
freshness, so nothing here can make a record match.

The measurement below is kept as the design rationale it was written as. Read on core-backend `origin/master`
b3ab901 / `origin/develop`, 2026-10-28 22:3xZ:

- **There is no `credit_proofs` table on master or develop.** It arrives with https://github.com/Muso-AI/core-backend/pull/10686 (open, develop: credit verifier evidence store). Its `kind` is a document vocabulary (`split_sheet`, `contract`, `invoice`, `label_letter`, `dsp_screenshot`, `liner_notes`, `other`, pinned by a CHECK constraint), and every row is bound to an uploaded or external file (`s3Key` / `sha256`). A DSP capture is not a file, so **no proof kind fits `dsp_anchor` or `dsp_label_line`**.
- **There are no credit cases on master or develop.** https://github.com/Muso-AI/core-backend/pull/10675 (master twin) is open; develop's #10641 was closed without merging.
- The credit-ops proof-backed endpoints that `agentApprovalGuard.js` refers to ("a separate PR") do not exist. `credit-trust-decide`'s `server_proof` scope SQL is literally `FALSE` ("no such table yet").
- What does exist: `POST /admin/credit-decisions` (`credit_decision_ledger`, kind `decision`, decider kind `fable` for `FABLE_DECIDER_ACCOUNTS`). It records decisions and vetoes. It never approves and is not an evidence store.

So per the ruling's step 3, **B's table was the shape the core PR was written to**: a server-written anchor
table that only this capture job's service account can write, plus a scope that admits a declined row only when
a record exists AND matches that row's request id, ISRC and role. Table as proposed, mirroring this record
(core's shipped shape is `anchor_upload.to_core_records`'):

```
credit_dsp_anchors(id uuid pk, request_id uuid not null, kind text check in ('dsp_anchor','dsp_label_line'),
  isrcs text[] not null, roles text[] not null, capture_request_id text, captured_at timestamptz,
  both_read boolean not null, record jsonb not null, record_sha256 char(64) not null,
  written_by text not null /* server: the authenticated account */, ruling_id text /* metadata */,
  created_at timestamptz not null default now())  -- append-only (no UPDATE/DELETE trigger)
```

The approve scope's SQL twin admits a row only on: an anchor row for the same `request_id`, `kind`, `isrcs`
overlapping the request's server-held ISRC, every approved role in `roles`, `created_at` within 24 h, and
`written_by` = the capture job's account. The executor never sends the record.

`anchors --write` exits 2: the subcommand only builds records into `dsp_anchors`. Posting built records to
core (`POST /admin/credit-anchors`) is `scripts/credit-anchors-push.py`, per approve tray.
