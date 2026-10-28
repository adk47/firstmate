# Caroline's real, safe actions (caroline-operator-c1)

> Captain, 2026-10-27 ~16:00Z: "are you taking control of caroline and talking to it with real actions for users inquiring status and providing documentation etc... top priority".

Audit that motivates this: `data/caroline-operator-c1/audit.md` (firstmate). On 27 Oct, none of the 50 credit/claim/merge conversations sampled got a real status action, and 45 ended in a ClickUp ticket. The waiting backlog reaches the document reader for 3 of 144 conversations where the customer sent a document.

## What ships (dark)

The `support-tools` plugin has four tools, behind `carolineActionsEnabled` (default **off**). Each one dispatches to `scripts/caroline-actions.py`, which owns every rule.

| Tool | Verb | What it does | Writes |
|---|---|---|---|
| `credit_status_lookup` | `status` | Reads core truth for the verified customer and returns **one approved line**, or none plus the refusal codes | Ledger row only |
| `document_intake` | `doc-intake` | Files every cached attachment of this conversation into the document reader's intake, with the user id and the candidate request or claim ids | Ledger + `doc_intake` queue |
| `merge_request_intake` | `merge-intake` → `create_ticket profile-merge` → `merge-record` | Files the merge request to the merge queue (a profile-merge ticket carrying the `merge_intake` block), once per request per 7 days | Ledger + `merge_intake`, plus the ClickUp ticket |
| `credit_trust_handoff` | `handoff` | Queues a case Caroline cannot decide for the credit-trust board (`board-export` writes the snapshot) | Ledger + `handoffs` |

None of the four approves, rejects, deletes or hides anything. The package has no path that writes to core: `test_caroline_actions.py` `NoWritePathTest` checks this.

None of them sends anything either. An approved line comes back as `reply_line` only while `/etc/hydra/caroline-actions-lines.enabled` exists, and that file is absent while the freeze holds. Until then each decision is still computed and ledgered as `line_withheld_locked`.

Kill switch: `/etc/hydra/caroline-actions.disabled`.

## Identity

The email comes from the conversation's **customer**, through `IntercomReader.getCustomerEmail`:
- the source author, when the author is a contact (user or lead);
- otherwise the conversation's one contact, read with `GET /contacts/{id}`.

It is never a model argument.

`getAuthorEmail`, which the older tools use, returns the **teammate** on any thread that our own outbound note opened. In the 27 Oct sample, 19 of 50 conversations returned `operations@muso.ai`, which is a staff account (user 28866). On those threads every ownership read fails or looks at the wrong account. The core lookup accepts exactly one confirmed account; anything else is `identity_unverified`.

## The only lines (no new copy)

Each line is verbatim from `scripts/intercom-verify-request.sh`, and the test reads the `.sh` and fails on any drift (`scripts/caroline_actions/copy.py`):
- `status-doc-received` (firstmate 070);
- `status-team-review` (the no-ask version, firstmate 070);
- `claim-status` (Fable claims-documentation-readiness-1023 r3).

All three say "Nothing else is needed from you right now". That is why every rule below exists.

There is no approved merge, dispute or ask wording, so those cases always end as a handoff.

## Refusals (each one has a test)

| Code | When |
|---|---|
| `identity_unverified` | The customer email maps to no Muso account, to several, or to an unconfirmed one |
| `facts_unknown` | Any source failed to read: core, verify ledger, proof-on-file, account gate or IDP list. UNKNOWN never answers |
| `owes_proof` | Any of: a `user_verification_needed` row; an `unverified` row whose IDP `review_*` rule fired; the account is on IDP's submitter hold list; a pending claim with no proof link. A filed document never clears this: it is not an accepted one |
| `account_hold` | The account gate's published hold set (`/opt/firstmate/fraud-lens/out/account_holds.jsonl`, read only; stale over 72 h means unknown) lists the account. Caroline never runs the gate |
| `status_note_hold` | `verify_ledger.py hold-silent` (Fable ruling 017) |
| `support_contact_held` | The customer emailed support@ in the last 90 days, so a person answers |
| `core_notice_within_7d` | Core delivered a notice in the last 7 days (`proofRequest.noticeSentAt`, `infoRequest.at`, `approvedNotice.noticeSentAt`, or a claim decision), per the sender map 2026-10-27 §4.1 |
| `status_changed_today` | A request or claim changed today, so core's own notice covers it |
| `hydra_note_within_7d` | Any `verify_messages` note was sent or attempted in the last 7 days |
| `caroline_line_within_7d` | Caroline was already given an approved line for this user in the last 7 days |
| `decided_not_closed` | A validator `reject_*` row is waiting on a person's ruling |
| `nothing_pending`, `no_titles`, `no_profile_name`, `multiple_pending_claims` | Nothing true to say, or a fact the line needs is missing |
| merge: `unsupported_kind`, `missing_profiles`, `keep_in_others`, `not_profile_ids`, `too_many_profiles`, `already_filed_within_7d`, `merge_in_flight` | |
| handoff: `unsupported_reason`, `already_handed_off_within_7d`, `no_conversation` | |
| doc-intake: `unsupported_subject`, `no_conversation`, `no_cached_attachment` | Only originals inside `<cache>/<conversation>/` are read; symlinks and PDF page renders are skipped |

When the customer owes proof, `document_intake` **still files the document**. Only the line is withheld, and filing never clears `owes_proof`.

Races: each dedupe check and its write share one `BEGIN IMMEDIATE` transaction: the own-line rule (`offer_line`), merge filing (`merge_claim`; a `to_file` row may already have a ticket, so it blocks a second filing for the full 7 days, and `merge-record` is retry-safe and never downgrades a filed row; the plugin retries a lost record once and otherwise answers `merge_record_failed` with the ticket id instead of a clean filing; if the ticket call itself throws, the answer is `merge_filing_outcome_unknown` with `next: credit_trust_handoff`, and the row stays `to_file` so the request cannot be filed twice), and the handoff (`handoff_claim`). Concurrent callers on separate connections get exactly one winner (`RaceTest`). Document rows dedupe on `UNIQUE (conv_id, sha256)`.

## Document intake → reader

`credit-proof.py intercom` (the `credit-verify-proof-intercom` cron) reads the `doc_intake` queue read-only (`caroline_actions.ledger.queued_docs`, last 30 days). It analyses the queued files whether or not the thread holds an admin ask. A reply to core's "We require more details" email opens a **new** thread, so the ask heuristic (`proof/intercom.py classify`) never sees it.

`intercom.intake_files` drops any path outside its own conversation directory.

The queue carries the user id and the candidate request or claim ids. The H3 store keys on the contact hash. Stage 2 and doc-verify can join on the queue; they do not read it yet.

## Sources

All sources are read-only and live from node-8:
- **Trino replica:** `users`, `credit_requests` (with the markers), `claiming`, `profile_merges`;
- **`/var/lib/hydra/credit-review/ledger.sqlite3`:** `verify_messages`, `verify_refusal_holds`;
- **`/var/lib/credit-trust/proof-on-file.json`:** through `verify_notify.load_proof_on_file`, with its freshness rules;
- **the account gate's published hold set** (a file read; Caroline never runs the gate);
- **`kubectl … industry-proc-raw-v2`:** `IDP_CREDIT_HOLD_SUBMITTER_IDS`. An empty list is an error, never "nobody is held";
- **the admin GET `/admin/profile/{id}`:** for the claim's profile name.

One lookup takes about 10 to 15 s, because each Trino query takes about 2 s.

Ledger: `/var/lib/hydra/caroline-actions/ledger.sqlite3`, mode 0600. It stores no email and no name, only the Muso user id and a contact hash.

## Replay (node-8, 27 Oct, read-only, temp ledger)

The status verb was run for the customers of the 50 sampled conversations.

**Result: no line for any of them.** The refusals, counted per conversation (one conversation can carry several):

| refusal | conversations |
|---|---|
| `owes_proof` | 20 |
| `core_notice_within_7d` | 19 |
| `status_changed_today` | 14 |
| `support_contact_held` | 5 |
| `hydra_note_within_7d` | 4 |
| `account_hold` | 2 |
| `decided_not_closed` | 2 |
| `nothing_pending` (not counting the 19 below) | 10 |

19 more resolved to the staff account through the old `getAuthorEmail` path, which the replay used. That is the identity bug above; the new tools use `getCustomerEmail`.

That is the honest answer for today's live traffic. Most people writing in owe proof while the asks are off, or core told them something this week. For them the real action is `document_intake` plus `credit_trust_handoff`, not a status sentence.

## Not in this PR

- No doctrine wiring in SOUL or skills telling Caroline when to call these tools. That belongs to caroline-teach-c1, after Fable's GO.
- No cron for `board-export`, and no board ingest route. The board would need a `POST /api/ingest/handoffs` contract, which is credit-trust-board-t03's lane.
- The `carolineActionsEnabled` flag stays off, and the lines switch stays absent.
- The proof asks stay locked.
