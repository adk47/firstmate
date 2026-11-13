# The claim document ladder

A claimant who cannot put a code on a bound page is told to send paperwork instead. Until this
ladder nothing read that paperwork: `claim_verify/decline_rules.py` declines a claim on a coded
contradiction, `claim-proof-check` reads a code on a bound page, and a document landed in
`proof_intake` and waited for a person who was never told it was there.

`scripts/claim-doc-ladder.py` (rules in `scripts/claim_verify/doc_ladder.py`, reads in
`scripts/claim_verify/doc_sources.py`) gives every open claim that has a document on file ONE
recorded decision with a reason code. It is the claim twin of `credit_review/doc_approve.py` and
has the same shape: extraction into a fixed schema, then coded predicates in rank order, then a
decision.

**It records. It changes no claim, calls no admin API and sends nothing.** Every decision is in
state `shadow`. Acting on one (approving a claim, declining one, telling a claimant) is a separate
step that does not exist yet and is a captain decision: see "What it does not do".

## When it runs

| Trigger | When | Why |
|---|---|---|
| `claim-doc-ladder.timer` | every 4 h at :40 | one pass is about 2 minutes; a document is read the same day it arrives |

The timer starts `claim-doc-ladder.service`. Both are written by `scripts/install-aux-units.sh`,
which **fails the deploy** if the timer cannot be enabled, started, or is not `active` afterwards:
with the timer down no document is read and the service's `OnFailure` cannot page because the
service never runs. A failed pass pages through the `AUX_ONFAILURE_UNITS` table.

Stop switch: `touch /etc/hydra/claim-doc-ladder.disabled`. The pass exits 0 and records nothing.

## What one pass does

1. **Reads** (`doc_sources.build`), all read-only:
   - every open claim (`pending`, `reverted`) with the account's own names, from core through Trino;
   - which of those profiles the catalog holds, and their release titles;
   - the claim side's own contradiction facts (`decline_rules.live_snapshots`, the read the decline
     executor already trusts);
   - the scheduled claim list, for a code found on a bound page;
   - the fraud lens's held accounts;
   - the documents on file for each claimant (`proof_intake`), each with the newest extraction
     doc-verify recorded for those bytes, its blocking verdicts, and how many OTHER accounts filed
     the same bytes.
2. **Decides** (`doc_ladder.plan`): pure, no clock, no network. Each document is walked down the
   ladder; the claim's decision is its best document's, and one forged, contradicted or reused
   document blocks an approval that another document would have earned.
3. **Records** (`doc_ladder.run`) into `/var/lib/hydra/claim-doc-ladder/decisions.sqlite`, and
   **retires** every standing row the pass did not decide: the claim closed, or its last document
   left the file. A retired row keeps what was decided and leaves `queue`.
4. **Re-derives** every recorded decision from what is stored (`doc_ladder.verify`). A decision
   that does not come out the same is exit 1 and a page: the store is not evidence until it is.

A read that does not answer raises. No snapshot is kept and nothing is recorded, so a failed read
never looks like "no documents". Because a pass retires what its snapshot does not hold, an open
claims read with no rows and a `proof_intake` with no rows raise too: "nothing answered" is never
"no claim is open". The last pass's summary is `latest.json` in the state directory.

The ladder does not extract. The extraction is the one doc-verify already recorded
(`dv_steps`, step `extract`), keyed by the document's sha256. A document doc-verify never read has
no extraction, and the ladder says so.

## The ladder

The first predicate that fails is the reason. `policies/claim-doc-ladder.json` holds every knob.

| # | Predicate | Passes when | Reason codes when it does not |
|---|---|---|---|
| 0 | readable | there is an extraction and it says something | `no_bytes_on_file`, `not_extracted`, `extraction_failed`, `degraded_extraction`, `empty_extraction` |
| 1 | names claimant | a party the document names (at `min_confidence` or better) is the claimant, under `credit_review.roles.names_match` | `claimant_name_unknown`, `claimant_not_named` |
| 2 | names profile | the document names the profile: by page id under `lib.page_identity` (equality, or a truncated prefix of 8+ characters), or by its catalog name under the same name rule | `profile_not_in_catalog`, `catalog_unreadable`, `profile_not_named` |
| 3 | document type | the type is one the claim class accepts | `claim_class_unknown`, `doc_type_not_accepted` |
| 4 | no contradiction | the claim's own contradiction rule finds nothing, no other account holds the profile, no other claim's code is on its bound page, and a release the document names is the profile's | `contradiction:<class>`, `profile_already_claimed`, `bound_code_unmeasured`, `bound_code_other_claim`, `releases_unmeasured`, `releases_not_on_profile`, `no_release_named` |
| 5 | clean | the document is not forged, contradicted or filed by a second account; the profile is not a big one; the account is not held | `document_forged`, `document_contradicted`, `document_reused`, `catalog_unreadable`, `big_profile`, `account_hold_unmeasured`, `account_hold` |

Passing all six is `approved` / `document_names_claimant_and_profile`.

Four outcomes, and each has a reason:

- **`approved`**: every predicate passed.
- **`refused`**: only a contradiction a document cannot cure (`refuse_on_contradiction`:
  `deceased_self_claim`, `test_account`). The reason is `contradiction:<class>`, never a bare denial.
- **`needs_human_review`**: everything else that was read. It is an outcome with a reason a
  person can work from, not a hold.
- **`unreadable`**: predicate 0 failed. A parsed-but-empty extraction is here, never in `approved`.

Rules that are code, not prose:

- **No document, no decision.** A claim with nothing on file gets no row. Absence approves nothing
  and refuses nothing.
- **The model's part ends at the extraction.** It says what the document says, in a fixed schema.
  It never returns approve or refuse and nothing asks it to.
- **Unmeasured is never a pass.** A fact that could not be read is its own reason
  (`bound_code_unmeasured`, `releases_unmeasured`, `account_hold_unmeasured`, `catalog_unreadable`).
- **A credits page is not accepted.** It is a public page anyone can screenshot: it shows the
  profile's name and nothing about who holds the account. 11 of the 15 claims the first real run
  would have approved stood on one.
- **One identity rule each, neither written here.** Names: `roles.names_match`. Page ids:
  `lib/page_identity.py`, which `ops_intake/lens_sources.py` now delegates to as well.

## The store

| Table | Holds | Changes |
|---|---|---|
| `claim_doc_decisions` | one row per claim: outcome, reason, the deciding document's sha256, the extraction's sha256, every gate's result, the exact inputs | see below |
| `claim_doc_extractions` | each extraction that was read, keyed by document sha256 + extraction sha256 | never: append-only |
| `claim_doc_events` | `decided`, `superseded`, `drift`, `released`, `redecided`, `retired`, `reopened` | never: append-only |

One decision per claim (`claim_id` is the primary key). On a later pass:

- the same decision is `unchanged`;
- a `needs_human_review` or `unreadable` decision is replaced when a new document or a new
  extraction changes it (`superseded`);
- an `approved` or `refused` decision is **not** replaced. A re-read that would now decide
  differently is logged once as `drift` and the row stands until a person releases it;
- a row whose claim is no longer open, or has no document on file any more, is `retired`
  (`state = 'retired'`, reason `claim_not_open_or_no_document`). It is not deleted and it is no
  longer listed as work. If the claim comes back it is decided on what is true then and stands
  again (`reopened`), an earlier `approved` or `refused` included: a retired decision does not
  stand, so it is not protected as one. A released row is left as the person left it.

`run --snapshot FILE` retires the same way, so only give it a snapshot of the whole open
population (`doc_sources --out`), never a hand-cut part of one. A wrong retirement undoes itself
on the next full pass.

## Working it

```bash
claim-doc-ladder.py queue                     # the claims a person decides, oldest first, reason on every row
claim-doc-ladder.py queue --outcome unreadable
claim-doc-ladder.py report                    # counts by outcome, reason and state
claim-doc-ladder.py verify                    # re-derive every decision; exit 1 on a mismatch
claim-doc-ladder.py release --claim-id N --by NAME --why "..."
```

`queue` prints one JSON line per claim with the predicate it stopped at and that predicate's
detail. To try a rule change against real rows without recording anything:

```bash
python3 -m claim_verify.doc_sources --out /dev/shm/snap.json     # the snapshot is 0600: it holds names
claim-doc-ladder.py plan --snapshot /dev/shm/snap.json --policy my-policy.json
```

## Revert, per field

| What | How it is undone |
|---|---|
| a `claim_doc_decisions` row | `release --claim-id N --by NAME --why "..."` marks it released with who and why; it stays released until a pass decides the claim differently |
| a retired row | nothing to run: it stands again on the first pass that finds the claim open with a document on file |
| `claim_doc_extractions`, `claim_doc_events` | never changed; they are the record of what was read and decided |
| a policy change | revert the PR; `approved` and `refused` rows made under it are released one by one |
| the whole ladder | the stop switch above, then `systemctl disable --now claim-doc-ladder.timer`; the state directory can be deleted, nothing reads it |
| core `claiming.status`, any message | not written by the ladder, so nothing to undo |

## What it does not do

- **It does not approve or decline a claim in core.** There is no executor. Wiring one is a new
  approval automation: it needs a row in `policies/credit-approval-automation.json` and a recorded
  captain decision before it can run.
- **It does not message anybody.** Telling a claimant "we could not read your document" or "we
  need a different one" is copy that goes through the outbound copy gate, and is not written.
- **It does not extract, and that is its largest gap today.** doc-verify selects a filed document
  by its candidate CREDIT requests (`docverify/intake_read.intake_docs`:
  `candidate_request_ids_json != '[]'`), so a document from a claimant with no open credit request
  is never read. In the first recorded run that is 51 of 192 claims: for all 51, every document
  with bytes has no candidate request and no dv-4 step of any kind. It is also most of the claims
  this ladder exists for: of the 12 open claims whose document arrived AFTER the claim proof ask
  was sent to them, 10 are `unreadable: not_extracted` and none is decided. The read itself already
  exists (`runner.verify_document` with an intake document and no keys records locate, text and
  extract and stops); what is missing is a selection that hands it these documents. That is a
  doc-verify change with its own cost (one model call per document under doc-verify's daily cap)
  and is not in this ladder.
- **It does not read a team claim.** 522 open claims carry no account (`userid` is null, the claim
  belongs to a team); documents are filed by account, so the ladder has no way to attach one.
- **It cannot tell a claim document from a credit document.** Every document on file today was
  filed with `subject = 'credit'`, the replies to the claim proof ask included: intake files
  nothing as `claim`. The ladder reads whatever the claimant's account has on file, so most of
  what it reads was sent for a credit, not for the claim.

Measured on real rows: `data/claim-doc-ladder-v2/report.md`.
