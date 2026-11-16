# The claim document ladder

A claimant who cannot put a code on a bound page is told to send paperwork instead. Until this
ladder nothing read that paperwork: `claim_verify/decline_rules.py` declines a claim on a coded
contradiction, `claim-proof-check` reads a code on a bound page, and a document landed in
`proof_intake` and nothing read it.

`scripts/claim-doc-ladder.py` (rules in `scripts/claim_verify/doc_ladder.py`, reads in
`scripts/claim_verify/doc_sources.py`) gives every open claim that has a document on file, or a
form its claimant supplied, ONE recorded decision with a reason code. It is the claim twin of
`credit_review/doc_approve.py` and has the same shape: extraction into a fixed schema, then coded
predicates in rank order, then a decision.

**Every decision is the ladder's own.** Captain, 2026-11-13: no verification path ends at a staff
queue. The ladder (`cdl-3`) has four outcomes and each names who moves next: the claimant, who is
owed a specific ask, or a job of ours, which owes a read. Nothing is parked for somebody to look at.

**Four forms, one verdict row.** Captain, 2026-11-16: "every row ends ASK (one specific ask) or NO
... escalation may be by email address, phone number or collaborator proof from an existing Muso
user". Until `cdl-3` the ladder knew one form (a document), so a claimant with no paperwork could
only be asked for paperwork, and 8,167 of the 9,147 documents on the credit side were credits
pages, none of which verified. A claim is now settled by a document, an email address, a phone
number or a collaborator's Muso profile; the row says which form settled it or which form it asked
in ("The four forms").

**It records. It changes no claim, calls no admin API and sends nothing.** Every decision is in
state `shadow`, the ask included: the row holds which ask the claimant is owed, and no claimant
has been sent one. Acting on a row (approving a claim, declining one, sending the ask) is a
separate step that does not exist yet and is a captain decision: see "What must be true before
anything acts on a row".

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
   left the file. A retired row keeps what was decided and leaves `list`.
4. **Re-derives** every recorded decision from what is stored (`doc_ladder.verify`). A decision
   that does not come out the same is exit 1 and a page: the store is not evidence until it is.

A read that does not answer raises. No snapshot is kept and nothing is recorded, so a failed read
never looks like "no documents". Because a pass retires what its snapshot does not hold, an open
claims read with no rows and a `proof_intake` with no rows raise too: "nothing answered" is never
"no claim is open". The last pass's summary is `latest.json` in the state directory.

The ladder does not extract. The extraction is the one doc-verify already recorded
(`dv_steps`, step `extract`), keyed by the document's sha256. A document doc-verify never read has
no extraction, and the ladder says so: `awaiting_read`, which is no verdict and no ask.

## The ladder

The first predicate that fails is the reason. `policies/claim-doc-ladder.json` holds every knob.

| # | Predicate | Passes when | Reason codes when it does not |
|---|---|---|---|
| 0 | readable | there is an extraction and it says something | `no_bytes_on_file`, `not_extracted`, `extraction_failed`, `extraction_gave_up`, `document_not_readable`, `empty_extraction` |
| 1 | names claimant | a party the document names (at `min_confidence` or better) is the claimant, under `credit_review.roles.names_match` | `claimant_name_unknown`, `claimant_not_named` |
| 2 | names profile | the document names the profile: by page id under `lib.page_identity` (equality, or a truncated prefix of 8+ characters), or by its catalog name under the same name rule | `profile_not_in_catalog`, `catalog_unreadable`, `profile_not_named` |
| 3 | document type | the type is one the claim class accepts; a class the policy does not name is held to the types every class accepts. It outranks an empty extraction: a document of an unaccepted kind that parsed and said nothing is refused on its kind | `doc_type_not_accepted` |
| 4 | no contradiction | the claim's own contradiction rule finds nothing, no other account holds the profile, no other claim's code is on its bound page, and a release the document names is the profile's | `contradiction:<class>`, `profile_already_claimed`, `bound_code_unmeasured`, `bound_code_other_claim`, `releases_unmeasured`, `releases_not_on_profile`, `no_release_named` |
| 5 | clean | the document is not forged, contradicted or filed by a second account; the profile is not a big one; the account is not held | `document_forged`, `document_contradicted`, `document_reused`, `catalog_unreadable`, `big_profile`, `account_hold_unmeasured`, `account_hold` |

Passing all six is `approved` / `document_names_claimant_and_profile`.

## The four forms

`scripts/claim_verify/forms.py` is the one table of what a claim can be proved by, which ask each
claim class is delivered in, and the check each supplied form gets. Nothing here reads a model, a
page or a network: a check is a pure function of (form, value, the facts the reader delivered).

| Form | What settles the claim | Offered for | State today |
|---|---|---|---|
| `document` | the ladder above: a document that names the claimant AND the profile | every class, every ask; the last rung of every ordering | read by doc-verify, unchanged |
| `email_address` | the claimant ACCOUNT's own address (core's `users.email`, read with the claim, carried as a digest) at a host the profile itself publishes, never free mail or a platform host, AND a mailbox core confirmed (`users.emailconfirmed`) — the account answered for that address, so it is one the claimant holds, at the profile's organisation | `company_authority` (organization), `proof_naming_profile` (organization, artist, professional) | **offered, and it settles** only where `profile_hosts`, a confirmed account address AND a domain that address shares with the profile were all read (`account_email_unread` / `account_email_not_confirmed` otherwise); an unconfirmed account is never offered it |
| `collaborator_proof` | another Muso user crediting the claimant on a release they share | `proof_naming_claimant`, `proof_naming_profile` (artist, professional) | **recognised, recorded and RESERVED**: nothing here can ask that user to confirm, and a public profile id anyone could paste is not their word, so `forms.FORMS_WITHOUT_A_CHECK` keeps it from being offered and a supplied one is a measured NO (`collaborator_attestation_not_recorded`) |
| `phone_number` | a number the profile publishes (company website) | `company_authority` (organization) | **never offered, and a supplied one is a measured NO**: no source publishes a profile phone to us, so the form is in `forms.FORMS_WITHOUT_A_CHECK`, `forms.check` refuses it as `no_source_can_check_this_form` and the row is `refused` with the ask that can still settle the claim — never `awaiting_read`, which would wait on a fact no job can ever read |

The rule is one sentence, and it is code (`forms.offered`, `forms.checkable`): **a claim is only
ever asked in a form whose facts were READ, and the document is the last rung** — so every row is
left with an ask its claimant can answer. The orders are in `forms.FORMS_BY_ASK` (per ask and
class); a class no form was reviewed for gets the document alone.

**What a typed string can never prove, and what settles instead.** Two of the four forms are ones
anybody could fake by typing, and this ladder settles on evidence we hold:

- **An address.** `madeup@novakane.com` is not proof of a mailbox. The address form settles only when
  BOTH hold: the supplied address IS the claimant account's own address — the one core holds for
  `users.email`, read with the claim and carried only as a digest (`account_email_sha256`) — at a
  domain the profile publishes, AND core has **confirmed** that mailbox (`users.emailconfirmed`, read
  as `account_email_confirmed`). An unconfirmed address is a typed string like any other, so an
  account whose mailbox core never confirmed is **never offered this form at all** (`checkable`
  needs both halves, and the document rung is the ask), and supplying one anyway is refused
  (`account_email_not_confirmed`) rather than left waiting. The same is true of a confirmed mailbox
  at a domain the profile does not publish (a `jane@gmail.com` account claiming a profile whose
  website is `brightlabel.com`): no answer could pass the check, so `forms.settles_at` — the one
  predicate the offer and the check share — keeps the document as the ask. **A mailbox challenge (a link we send and
  they click) is a later change**; until then the settled fact is core's own confirmation, which is
  what makes the address one the claimant's account answered.
- **A collaborator.** A public profile id is not that user's word, and no reply path exists here to
  ask them. So collaborator proof is **recognised, accepted by the intake and recorded**, never
  offered and never approving: a supplied one is refused as `collaborator_attestation_not_recorded`
  and its words sit in `reserved_form_asks`. **The collaborator's own confirmation is the missing
  piece**, and shipping a form that claims it without that is exactly the offer we must not make.

A read that does not answer (the account's address, the profile's host) is `awaiting_read`, never a
pass.

**A shared host never settles.** An address at a free-mail provider or at a platform or link hub
(`forms.SHARED_HOSTS`, instagram.com and linktr.ee among them, subdomains included) is somebody's
free account, not an organisation's own domain, so it is refused (`email_at_free_mail`,
`email_at_a_shared_host`) even when the profile itself links to that platform.

**Unmeasured is not a refusal, and a measured absence is not unmeasured.** A check whose fact could
not be read answers `None`, the ladder records `form_unmeasured` (`awaiting_read`, route
`doc-sources`) and the claimant is asked for nothing while the fact is unread. A profile we read
that publishes no website is `[]`, not `None`: that is measured, and it refuses the address. A
profile the catalog does not contain is credited on nothing, which refuses the collaborator.

**A form that checks out is not an approval on its own.** It is held to the same claim-side stops a
document is (`_contradiction_stop`, `_clean_stop`): the claim list's own contradiction rule, another
account holding the profile, a bound code another claim already found, a big profile, an account
hold. A document on file that is poisoned — forged, contradicted, or filed by a second account —
poisons the form path too, so a form never launders a claim a document already made unsafe. Each
stop's own reason is recorded, and an unread one is `awaiting_read`.

**What the row says, and where the value is.** Worth knowing when reading a `list` line:
`ask_form` is the form the ask is delivered in, `form` is the supplied form the decision stood on
('' when a document settled it or nothing settled it), and `form_value_sha256` is the digest of what
was supplied. **The address, the number and the collaborator's id are never on the verdict row**,
never in the stored inputs and never in an event: the value lives on the append-only
`claim_doc_supplies` row, and in the pass's own `snapshot.json` (0600, in the state directory) while
the pass decides. `verify` re-reads the value from the supply row by that digest, so a decision is
still re-derivable after a restore, and a decision whose supply row is missing is reported as a
mismatch rather than guessed.

### A form arrives through the intake, and the intake decides nothing

```bash
claim-doc-ladder.py supply --claim-id N --form email_address --value jane@novakane.com \
    --intake-id <the reply's own id> --received-by <the channel it arrived on>
```

`supply` normalises the value (lower-cased address, `+`-and-digits number, profile id), refuses a
malformed one and refuses a document, and appends a row to `claim_doc_supplies`. It **records only**:
the next pass reads the supplies (`doc_sources.supplies`), attaches them to the claim with the facts
their checks need (`doc_sources.form_facts`), and decides the claim as it decides any other. A claim
whose only evidence is a form is in the population at all, and one with neither a document nor a form
is still `no_evidence`.

The collaborator facts are kept **per reference** (`collaborators: {ref: {in_catalog, titles}}`), so a
claimant who sends two collaborators has each checked on its own record, and a reference is matched
the one page-identity way (`lib/page_identity.same_page`), so a truncated id a ticket or a register
row holds still finds its profile. The copy a verdict row stores keys the same facts by the value's
digest, and `verify` re-keys them from the supply row, so the stored inputs hold no reference either.

The table is **append-only** (triggers, like `claim_doc_events`): a wrong supply is answered by a
new row and the check takes the best one, so nothing here needs anyone's approval to undo.

**The live reads are bounded, and nothing is left out twice.** `profile_hosts` comes from the live
admin profile (`gdpr_pipeline.sources.profile_sites`, never the catalog view, which ran four days
behind). One pass reads at most `doc_sources.MAX_FORM_READS` profiles: a claimant who supplied an
address is ALWAYS read (waiting on a fact we never read would wait forever), and the rest are taken
oldest-supply-first after last pass's reads (`latest.json` → `form_hosts_read`), so a profile left
out this pass is read on the next one. What stayed out is counted (`form_over_bound`), never
silently dropped: the address form is simply not checkable for that claim, so `forms.offered`
falls through to the next form whose facts were read, and the document — checkable always — is the
last rung of every ordering.

### The ask copy carries a line per form

`policies/claim-doc-asks.json` is `cda-2`: the document lines are **byte-identical** to `cda-1`, and
`form_asks` holds the words each ask is delivered in when it is not a document. The ladder refuses
to load the file when a pair it can choose has no words, or when it carries a pair it never chooses,
and the identity-document scan covers these lines too. **Nothing sends them**: same rule as the
document asks, and their exact bytes are what a sender would put through the outbound copy gate.

## The four outcomes

| Outcome | Means | Who moves next | The row carries |
|---|---|---|---|
| `approved` | every predicate passed | nobody | the reason `document_names_claimant_and_profile` |
| `refused` | a document was read and does not prove the claim | the claimant | the internal reason, and the ask: what to send instead |
| `resend` | doc-verify gave its last answer on the document and nothing in it could be read | the claimant | the reason, and the ask `readable_copy`: a clear copy, or a link |
| `awaiting_read` | we have not read something: the document, or a fact about the claim | a job of ours | the reason, and the route: the job that owes the read |

`refused` and `approved` are verdicts. `resend` and `awaiting_read` are not: neither says anything
about the claim. The store refuses a row that breaks the pairing (a `refused` or `resend` row
with no ask, an `awaiting_read` row with no route, any other outcome).

### Reason to ask

`REASONS` in `doc_ladder.py` is the one table: every reason code maps to its outcome and to its ask
or its route, and the module does not import if a reason has neither (`_check_reasons`). A new
reason cannot arrive without one. The reason is ours and is never an input to the words a
claimant reads (`ask_text` takes the ask, the claim class, the policy and the copy file).

| Reason | Outcome | Ask |
|---|---|---|
| `claimant_not_named` | refused | `proof_naming_claimant`: a document that shows the claimant's own name |
| `claimant_name_unknown` | refused | `account_name`: a name on the account, then a document that shows it |
| `profile_not_in_catalog` | refused | `claimed_profile_link`: the link to the profile being claimed |
| `profile_not_named` | refused | `proof_naming_profile`: a document that shows the profile's name or its link |
| `doc_type_not_accepted` | refused | `accepted_document_type`: the types this claim class accepts, named |
| `no_release_named`, `releases_not_on_profile` | refused | `release_on_profile`: a document that names a release listed on the profile |
| `document_forged`, `document_contradicted` | refused | `document_from_issuer`: the document as its issuer provides it |
| `document_reused` | refused | `own_document`: a document issued to the claimant |
| `bound_code_other_claim`, `big_profile` | refused | `claim_code_on_page`: the claim code, on a page the profile already links to |
| `contradiction:another_persons_profile`, `contradiction:contradicted_by_own_claims` | refused | `claim_code_on_page` |
| `contradiction:individual_claims_company` | refused | `company_authority`: the company's own authorisation, from its domain |
| `contradiction:test_account`, `contradiction:deceased_self_claim`, `contradiction:impersonation`, `profile_already_claimed`, `account_hold` | refused | `nothing_to_send`: no document changes this refusal |
| `extraction_gave_up`, `document_not_readable`, `empty_extraction` | resend | `readable_copy`: a clear copy of the document, or a link to it |

| Reason | Outcome | Route |
|---|---|---|
| `not_extracted`, `extraction_failed` | awaiting_read | `doc-verify`: credit-doc-verify reads the document |
| `no_bytes_on_file` | awaiting_read | `byte-restore`: the `credit-doc-verify-blob-backfill` cron restores the bytes (`credit-doc-verify.py blob-backfill`), and credit-doc-verify reads them. **The cron ships switched off**: see below |
| `catalog_unreadable`, `bound_code_unmeasured`, `releases_unmeasured`, `account_hold_unmeasured` | awaiting_read | `doc-sources`: the `claim-doc-ladder.timer` run re-reads the catalog, the claim list and the hold ledger |

Every route is one row in `doc_ladder.ROUTES`, with the script it runs and the schedule that runs it:
a cron in `cron-jobs.json` (checked by a test, and a route naming neither a cron nor a timer unit
refuses to register) or the ladder timer. Whether a cron is switched on is not assumed from that
table. `doc_ladder.job_state` reads `cron-jobs.json` each time a waiting row is reported, and
`report`, `list` and `awaiting` in `latest.json` carry the answer as `job`: `enabled`, `disabled`,
`missing`, `unread` (the file could not be read, which is not `enabled`) or `timer` (the ladder's
own pass). A row whose job is `disabled` has no read coming until the job is armed.

### The byte-restore job ships switched off

`credit-doc-verify-blob-backfill` is in `cron-jobs.json` with `enabled: false`. Arming it is a
separate, deliberate change, never a side effect of a merge.

| | |
|---|---|
| What one run does | For each support@ email filing whose attachment was filed without its bytes: one Gmail message fetch, which fills every attachment filed from that message. For each stored Intercom blob that went missing: the filer's cache copy, else one Intercom fetch. The bytes go into the doc-verify blob store (`/var/lib/hydra-credit-verify/blobs`) and are registered in `doc-verify.sqlite`. It reads the proof store read-only |
| What it costs | No model call. At most 20 Gmail message fetches (paced 6 a minute, on the shared support@ Gmail lock and its hourly quota) and 20 Intercom fetches (paced 1 a second) per run; at `20 * * * *` that is at most 480 of each a day. It stops at once on a quota refusal and records the provider's retry time |
| What the first run does to the store | It adds up to 40 blobs and their rows. It deletes and overwrites nothing. The backlog it would start on has not been measured for this PR; the ladder counted 32 claims waiting on bytes on 2026-11-13 |
| What stops it | Any one of three kill files, checked before a store is opened or anything is fetched: `/etc/hydra/credit-doc-verify-blob-backfill.disabled` (this job only), `/etc/hydra/credit-verify.disabled`, and the support@ readers kill file `/etc/hydra/gmail-readers.disabled`. The `enabled` flag is in a file every deploy overwrites; the kill files are on the host |
| What it never does | Approve, change a claim or a credit, or send anything |

Until it is armed, a `no_bytes_on_file` claim waits and is reported as waiting on a switched-off
job. No route names a command a person runs, and no route names the ladder's own pass as the
reader of a fact it does not read.

An `awaiting_read` row keeps the day it was first decided: a pass that re-reads the same
unreadable fact changes nothing, and `report` prints that age per (route, reason), `list` prints it
per row, and `latest.json` carries the same list as `awaiting`, so a claim nobody can move is
visible rather than silently re-queued.

Every contradiction class the claim side can raise (`credit_review.claim_executor.CONTRADICTIONS`)
has an ask in `CONTRADICTION_ASKS`; a class without one raises instead of recording.

The words for each ask are in `policies/claim-doc-asks.json` (`cda-1`). The ladder refuses to load
that file when an ask has no words, when it names an ask the ladder does not have, or when a
document type the policy accepts has no phrase. The words are not in the decision key: rewording
an ask re-decides nothing.

**No ask names an identity document.** A claim is proved by music paperwork that names the
claimant and the profile. The file does not load when an ask or a type phrase names a passport, a
licence, an ID or the like (`IDENTITY_DOCUMENT` in `doc_ladder.py`).

### Our failure or their document

A document that was not read is never a refusal, and the claimant is never asked for something
because a job of ours has not run. Two questions decide it, and both are doc-verify's own rules,
read by `doc_sources` and not written again in the ladder:

1. **Will a job still read it?** `read_final` is `docverify/runner.extract_settled`: the newest
   extract answer is `ok`, or it is an error doc-verify does not retry, or the attempts ran out
   (`MAX_EXTRACT_ATTEMPTS`). While it is false the document is ours: no extraction yet
   (`not_extracted`), bytes never stored (`no_bytes_on_file`), or a failed read doc-verify will make
   again (`extraction_failed`). All three are `awaiting_read`.
2. **Whose failure was the last read?** Only asked once the answer is final. `tooling_error` is
   `docverify/gate.TOOLING_ERRORS` (the bytes could not be located, the sandbox failed, the provider
   or the spend cap, a stored answer that is not JSON): reason `extraction_gave_up`. Otherwise the
   file itself held nothing to read: `document_not_readable`, or `empty_extraction` when it parsed
   and said nothing.

Both final answers are `resend` with the same ask, because a copy we can read is the only way
forward either way. The reason records whose failure it was; the ask does not, and its words say
that we could not open the document, not that the claimant sent a bad one.

A claim is asked for nothing while any of its documents is still ours to read: the one we have not
opened may be the proof. So one unread document makes the whole claim `awaiting_read`, ahead of
any refusal another document would have earned. **This ladder adds no read of its own**: an
`awaiting_read` row leaves only when the job named in its route does its work, and how many rows
each job owes, and how long the oldest has waited, is `awaiting` in `latest.json`.

Rules that are code, not prose:

- **No document, no decision.** A claim with nothing on file gets no row. Absence approves nothing
  and refuses nothing.
- **The model's part ends at the extraction.** It says what the document says, in a fixed schema.
  It never returns approve or refuse and nothing asks it to.
- **Unmeasured is never a pass and never a refusal.** A fact that could not be read is its own
  reason (`bound_code_unmeasured`, `releases_unmeasured`, `account_hold_unmeasured`,
  `catalog_unreadable`) and its outcome is `awaiting_read`.
- **Every contradiction refuses.** The policy no longer chooses which classes do
  (`refuse_on_contradiction` is gone); the class chooses the ask.
- **A credits page is not accepted.** It is a public page anyone can screenshot: it shows the
  profile's name and nothing about who holds the account. 11 of the 15 claims the first real run
  would have approved stood on one.
- **One identity rule each, neither written here.** Names: `roles.names_match`. Page ids:
  `lib/page_identity.py`, which `ops_intake/lens_sources.py` now delegates to as well.

## The store

| Table | Holds | Changes |
|---|---|---|
| `claim_doc_decisions` | one row per claim: outcome, reason, ask, the form the ask is in, the form that settled it and that form's digest, route, the deciding document's sha256, the extraction's sha256, every gate's result, the exact inputs | see below |
| `claim_doc_supplies` | each email address, phone number or collaborator a claimant supplied, normalised, with its digest, the intake it arrived on and the channel it was received on (never a person's name) | never: append-only |
| `claim_doc_decisions_cdl1` | the rows the older ladder (`cdl-1`) recorded, set aside whole on the first `cdl-2` pass | never |
| `claim_doc_extractions` | each extraction that was read, keyed by document sha256 + extraction sha256 | never: append-only |
| `claim_doc_events` | `decided`, `superseded`, `drift`, `released`, `redecided`, `retired`, `reopened` | never: append-only |

One decision per claim (`claim_id` is the primary key). On a later pass:

- the same decision is `unchanged`;
- a decision that differs replaces the row (`superseded`): a new document, a new extraction, a
  fact that changed. A `refused` row is replaced like any other, since a claimant who answers the
  ask sends a new document;
- one exception: an `approved` row is **not** replaced by `awaiting_read`. A read we could not
  make this pass is not evidence against a claim a document proved. It is logged once as `drift`
  and the approval stands. A measured `refused` or `resend` does replace it;
- a released row is decided again on the next pass (`redecided`);
- a row whose claim is no longer open, or has no document and no supplied form on file any more, is
  `retired` (`state = 'retired'`, reason `claim_not_open_or_no_document`). It is not deleted and it
  is no longer listed. If the claim comes back it is decided on what is true then and stands again
  (`reopened`).

No row waits for a release: `release` is an operator's undo and no claim's next step.

**`cdl-3` adds columns to a store it already has.** The first `cdl-2` pass on a store the oldest
ladder wrote renamed its `claim_doc_decisions` to `claim_doc_decisions_cdl1` and decides every open
claim again (those rows hold outcomes this ladder does not have, `needs_human_review` and
`unreadable`). **`cdl-3` renames nothing**: `open_store` adds the three form columns in place
(`migrate_form_columns`), no row is re-decided, and a row written before them says nothing about a
form, which is exactly what "a document settled it" means. Nothing is deleted; the event log and
the extractions are untouched. A read-only open (`open_store_ro`) changes nothing: it refuses, in
words, only a store this ladder cannot read at all (one written before `cdl-2`, which has no
`awaiting_read` outcome), telling the reader to run a pass. A store the ladder can read but which
predates the form columns is read as it is - `_col` answers `''` for a column it lacks - so
`report` and `list` show a row that says nothing about a form rather than raising `no such column`,
and `verify` reports such a row as not reproduced rather than guessing at it (the decision key
carries `doc_ladder.VERSION`).

`run --snapshot FILE` retires the same way, so only give it a snapshot of the whole open
population (`doc_sources --out`), never a hand-cut part of one. A wrong retirement undoes itself
on the next full pass.

## Working it

```bash
claim-doc-ladder.py list                      # the standing refusals, paying claimants first, each with the ask its claimant is owed
claim-doc-ladder.py list --outcome resend     # or awaiting_read (each with the job that owes the read), or approved
claim-doc-ladder.py report                    # counts by outcome, reason, ask, route and state, and the age of each awaiting class
claim-doc-ladder.py verify                    # re-derive every decision; exit 1 on a mismatch
claim-doc-ladder.py release --claim-id N --by NAME --why "..."
claim-doc-ladder.py supply --claim-id N --form email_address --value jane@novakane.com \
    --intake-id <the reply's own id> --received-by <the channel it arrived on>   # record a supplied form
```

`list` prints one JSON line per claim with the predicate it stopped at, that predicate's detail,
the ask or the route, `ask_form` (the form the ask is delivered in), `form` (the supplied form the
decision stood on, '' for a document) and `form_value_sha256`, and for an asked row `ask_text`:
the words a sender would use, in that form. A row we owe
the read of carries `age_hours` instead: how long that decision has stood. It is a read
of the record, not a worklist. To try a rule change against real rows without recording anything:

```bash
python3 -m claim_verify.doc_sources --out /dev/shm/snap.json     # the snapshot is 0600: it holds names
claim-doc-ladder.py plan --snapshot /dev/shm/snap.json --policy my-policy.json
```

## Revert, per field

| What | How it is undone |
|---|---|
| a `claim_doc_decisions` row | `release --claim-id N --by NAME --why "..."` withdraws it with who and why; the next pass decides the claim again |
| a `claim_doc_supplies` row | append a corrected supply; the check takes the best one, so nothing is undone in place |
| the `cdl-3` store shape | nothing to run: the form columns are added in place and a row that says nothing about a form means a document settled it. Reverting the code leaves the columns, which the older ladder ignores |
| the `cdl-2` store shape | with the timer stopped and the older code deployed: `ALTER TABLE claim_doc_decisions RENAME TO claim_doc_decisions_cdl2; ALTER TABLE claim_doc_decisions_cdl1 RENAME TO claim_doc_decisions;` |
| an ask's words | revert the line in `policies/claim-doc-asks.json`; no row changes, the words are not in the decision key |
| a retired row | nothing to run: it stands again on the first pass that finds the claim open with a document or a supplied form on file |
| `claim_doc_extractions`, `claim_doc_events` | never changed; they are the record of what was read and decided |
| a policy change | revert the PR; the next pass decides every claim under the restored policy and replaces the rows that differ |
| the whole ladder | the stop switch above, then `systemctl disable --now claim-doc-ladder.timer`; the state directory can be deleted, nothing reads it |
| core `claiming.status`, any message | not written by the ladder, so nothing to undo |

## What must be true before anything acts on a row

The ladder decides and records. Three things do not exist, and each is its own change:

| To | It needs |
|---|---|
| send a claimant the ask on a `refused` or `resend` row | a sender that is a row in `policies/outbound-copy-senders.json`, whose exact bytes pass `scripts/outbound_copy/gate.py` (the lines in `policies/claim-doc-asks.json` have not been through it), that keeps the existing re-ask lock and unmeasured stop as they are, and a captain decision on the copy |
| approve or decline a claim in core from a row | an executor registered in `policies/credit-approval-automation.json` with a recorded captain decision |
| read a document an `awaiting_read` row is waiting on | the job in the row's route to do it; this ladder starts no read and spends no model call |

Until the first exists, a `refused` row is a decision with an ask nobody has received.

## What it does not do

- **It does not approve or decline a claim in core.** There is no executor.
- **It does not message anybody.** The ask is recorded by name; its words are in
  `policies/claim-doc-asks.json` and nothing sends them.
- **It does not retry a read.** doc-verify re-reads a document only after a failure it counts as
  transient, up to `MAX_EXTRACT_ATTEMPTS` answers. A document with no readable text, or one that
  parsed and said nothing, is final on its first read.
- **It does not extract; doc-verify does.** doc-verify selected a filed document by its candidate
  CREDIT requests only (`docverify/intake_read.intake_docs`: `candidate_request_ids_json != '[]'`),
  so a document from a claimant with no open credit request was never read: 51 of 192 claims in the
  first recorded run, and 10 of the 12 open claims whose document arrived AFTER the claim proof ask.
  `docverify/runner.claim_only_docs` now selects those filings when the account has an open claim
  (110 documents of 48 accounts on 2026-11-13, read-only on the live stores: the decided document of
  all 51 `not_extracted` claims is among them; 12 more are owed by `blob-backfill`) and hands each to
  `runner.verify_document` with no keys, which records locate, text and extract and stops: no claim
  key, no H3, no outcome row. They are read behind the credit filings and ahead of the re-reads,
  at one model call per document under doc-verify's daily cap: the room the credit filings leave in
  `--max-docs`, and never fewer than 5 per worker on top of it (`runner.claim_only_room`; with the room
  alone the first deployed run read none of them, `data/verif-claim-doc-extract-r1/report.md`). The
  open-claim accounts are one replica read an hour (`runner.claim_accounts`, kept in `dv_state`);
  when that read fails or answers nothing, or `proof_intake` cannot be read, none of these filings
  is selected and the run reports it as an error. A filing whose bytes were never stored is still
  `no_bytes_on_file`.
- **It does not read a team claim.** 522 open claims carry no account (`userid` is null, the claim
  belongs to a team); documents are filed by account, so the ladder has no way to attach one.
- **It cannot tell a claim document from a credit document.** Every document on file today was
  filed with `subject = 'credit'`, the replies to the claim proof ask included: intake files
  nothing as `claim`. The ladder reads whatever the claimant's account has on file, so most of
  what it reads was sent for a credit, not for the claim.

- **`claim_code_on_page` presumes a page to put the code on.** The ladder does not read whether
  the profile links to one.

Measurement pointers: real rows under `cdl-1` → `data/claim-doc-ladder-v2/report.md`. The same
population's shape under `cdl-2`, on a synthetic fixture: `data/claims-no-human-p1/report.md`.
`cdl-3` is measured by `scripts/tests/test_claim_forms.py`; the ask copy is pinned by
`doc_ladder.check_ask_copy`, which `claim-doc-ladder.py list` (`load_ask_copy`) and the tests load,
so the policy file and the renderer cannot disagree.
