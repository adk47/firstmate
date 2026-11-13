# Claim document ladder: first run on real rows

Run 2026-11-12 21:03Z on node-8, branch `fm/claim-doc-ladder-v2` at the commit that is `49e194271`
after the rebase onto main (`3b8ed4946` when it ran), not deployed.
Sources were the live ones, read-only (core and catalog through Trino, `proof.sqlite`,
`doc-verify.sqlite`, the claim list, the hold ledger). The store was a scratch directory in
`/dev/shm`, so nothing under `/var/lib` was written, no claim was changed and nothing was sent.
Operator doc: `docs/credit-verification/claim-doc-ladder.md`.

## The result in one paragraph

Every open claim that has a document on file now gets one recorded decision with a reason code,
and all 192 re-derive from what is stored. **1 is auto-decided, 105 need a person, 86 are
unreadable.** The ladder is not yet evaluating the documents it was built for: of the 12 open
claims whose document arrived after the claim proof ask was sent to them, none is decided, and 10
of the 12 cannot be, because doc-verify never extracted them.

## What was read

| | |
|---|---|
| open claims (`pending`, `reverted`) | 3,272 |
| of those, team claims with no account (not read: documents are filed by account) | 522 |
| open claims whose claimant has NO document on file (no decision, by rule) | 2,558 |
| open claims whose claimant has a document on file | **192** (132 claimants) |
| documents on file for those claimants | 460 (311 with bytes on disk) |
| documents filed as `subject = 'claim'` | 0: every one is filed as `credit` |

The brief's "437 documents on file for paid, 203 let through by a stage-2 verdict" are lines of the
credit side's paid status run (`credit_review/uvn_status.py`): they count credit users, not claim
documents. I did not re-derive them. The claim-side population is the 192 above, of which 26 are
on the claim list as paid, 97 as not paid, and 69 are not on the claim list at all.

## The split

| Outcome | Claims | |
|---|---|---|
| auto-decided: `approved` | 1 | |
| auto-decided: `refused` | 0 | no claim with a document carries a contradiction a document cannot cure |
| `needs_human_review` | 105 | |
| `unreadable` | 86 | |
| **decided** | **192** | recorded twice: pass 1 `decided: 192`, pass 2 `unchanged: 192`; `verify`: 192 reproduced, 0 mismatched |

By reason, with one sample claim each (claim id, class/status, document type, the predicate it
stopped at):

| Outcome | Reason code | Claims | Sample |
|---|---|---|---|
| approved | `document_names_claimant_and_profile` | 1 | 1622734, artist/pending, `dashboard_screenshot`, passed all six |
| needs_human_review | `claimant_not_named` | 58 | 173096, organization/reverted, `credits_page`: 6 parties named, none is the claimant |
| needs_human_review | `profile_not_in_catalog` | 25 | 255427, professional/reverted: the claimed profile has no `catalog_profile` row |
| needs_human_review | `doc_type_not_accepted` | 12 | 164021, artist/reverted, type `other` |
| needs_human_review | `profile_not_named` | 7 | 1612819, artist/pending, `pro_registration`: names the claimant, not the profile |
| needs_human_review | `no_release_named` | 2 | 1619791, artist/pending, `dashboard_screenshot`: names no release of the profile |
| needs_human_review | `releases_not_on_profile` | 1 | 1618686, artist/pending, `dashboard_screenshot`: the one release it names is not the profile's |
| unreadable | `not_extracted` | 51 | 175640: bytes on disk, never read by doc-verify |
| unreadable | `no_bytes_on_file` | 26 | 238244: an intake row with no file |
| unreadable | `extraction_failed` | 8 | 183263: `no readable text` |
| unreadable | `empty_extraction` | 1 | 1623165: parsed, says nothing |

Where the ladder stopped: readable 86, names claimant 58, names profile 32, document type 12, no
contradiction 3, passed all 1.

By class: artist 1 approved / 82 review / 63 unreadable; organization 0 / 21 / 22; professional
0 / 2 / 1. By paid: paid 0 / 13 / 13; not paid 1 / 57 / 39; not on the claim list 0 / 35 / 34.

## The one approval

Claim 1622734. I read its stored extraction, not the image. It is a collecting-society dashboard
screenshot (issuer type `pro`, confidence 0.96) that lists four performers on one track; one of
them is the claimant's full name at 0.99, the profile's catalog name is that name under the name
rule (it differs by a hyphen), and the
track is on the profile (popularity 42, 5 credits, account not held, document filed by no other
account). The account has 4 documents on file and all four name releases on the profile.

What the ladder cannot see: whether the screenshot is a member's logged-in view or a lookup anyone
can run. It is recorded in shadow like every other row.

## What changed between the first plan and this run

The first plan on the same rows approved **15**. Reading them: 11 of the 15 stood on a
`credits_page`, a public page anyone can screenshot, which shows the profile's name and nothing
about who holds the account. Two rules were added before anything was recorded:

- a credits page is not an accepted type for any claim class;
- a document must name a release that is on the profile (`require_release_on_profile`), which is
  what the approved ask copy asks for.

That took 15 to 1. Both are one-line policy settings in `policies/claim-doc-ladder.json`.

## Limits, measured

1. **The replies to the claim ask are not being read.** 366 claims were sent the claim proof ask
   between 2026-10-30 and 2026-11-12. 12 of the 192 are among them, and each has a document that
   arrived after its ask. Their decisions: 10 `unreadable: not_extracted`, 2
   `needs_human_review: claimant_not_named`. For all 51 `not_extracted` claims, every document with
   bytes has no candidate credit request and no dv-4 step: doc-verify selects a filed document by
   its credit requests (`docverify/intake_read.intake_docs`), so a claim-only filer is never
   selected. The fix is a selection in doc-verify that hands these documents to
   `runner.verify_document` with no keys, which already records locate, text and extract and
   stops. It costs one model call per document under doc-verify's daily cap and touches a read
   budget with reviewer rulings on its order, so it is not in this change.
2. **Most of what was read is credit paperwork.** Intake files nothing as `claim`, so the ladder
   reads whatever the account has on file. That is why `claimant_not_named` is the largest reason:
   58 claims whose documents name other people.
3. **25 claims are on a profile the catalog does not hold.** 74 open claims with a document point
   at a profile with no `catalog_profile` row. A sample of 12 read through the admin API: 11 exist
   there, 1 could not be read. The ladder reads names and releases from the catalog, so these go to a person.
4. **26 claims' best document is an intake row with no file.** The bytes were never stored.
5. **522 team claims are not read at all.**
6. **Nothing acts on a decision.** No executor, no message, no person paged for the review queue.
   `claim-doc-ladder.py queue` is the list; nobody is assigned to work it.

## Reproduce

```bash
python3 -m claim_verify.doc_sources --out /dev/shm/snap.json
claim-doc-ladder.py plan --snapshot /dev/shm/snap.json
```

Tests: `scripts/tests/test_claim_doc_ladder.py` (93; 84 when this run was recorded, 9 added with the
retire step), `scripts/tests/install-aux-units-claim-doc-ladder.bats` (15).
