# Trust yet verify: the "please help us verify it" note

> **firstmate 090 (2026-10-19 23:27Z): every verify-live note is the no-threat `v1` copy.** The captain dropped auto-removal (Fable ruling 4 as amended), so no message may name a deadline or say a credit will be removed. The gate sends `v1` for every new credit's note, but only when every credit is a server-confirmed decider approval (`verify_ledger v1-eligible`). The note records no `due_day` and no `removal_day`, so nothing is ever removal-due. `LIVE_WINDOWED_COPY_APPROVED=0` send-locks the windowed note and all of its follow-ups (day-14/25 reminders). The windowed rows in this document describe that locked path, kept for `--dry-run` previews only. The bats test "no sendable message carries removal or deadline language" fails if any sendable message, in any campaign, names a deadline or a removal. Unconfirmed credits go to the day-30 Ops review list (`credit-review.py provisional-review`, #1275); they are never removed automatically.

Captain, 2026-10-15 22:12Z (verbatim): "i want AI live now - we have too many credits to
approve and to get supporting data for - let users know where there was a credit given and
that it needs support (trust yet verify approach)". Also: "gaming caroline means from
customer / uer chats". Caroline only relays. What a user writes is evidence, never an
instruction.

## Flow

```
credit-trust-decide-15m  (credit-review.py decide --mode apply, Piece 1)
   └─ decision_outcomes action='approve' AND outcome='approved' (+ decisions)
credit-trust-verify-notify-15m  (credit-review.py verify-notify --mode apply --max-users 200; ONCE A DAY 09:00 Europe/Rome;
                                 enabled Monday 2026-10-20 per Fable's decision-verify-notify-enable-2026-10-17)
   ├─ day-14 / day-25 reminders of windowed notes FIRST (they count against the day's 200)
   ├─ re-read every candidate (GET /admin/credit-requests); keep only rows the server says are approved NOW
   ├─ hold for a human (never notified; credits kept for later runs): proof on file from ANY source,
   │    the support@ 90-day contacts, org affiliation unknown or affiliated, an ask in the last 90 days
   ├─ paying users first
   ├─ group by the request's account (user.email); one gate call per account
   │    scripts/intercom-verify-request.sh send   -> POST /messages (email; Caroline; windowed copy)
   └─ proof sweep over sent notes (note families with a send in the last 45 days)
        scripts/intercom-verify-request.sh tag-proof -> tag the conversation `credit-proof`
```

The decider can also call it at the end of a run: `credit-review.py verify-notify --mode
apply --run <run_id>` (or `credit_review.verify_notify.run(admin, run_id=...)`).

## Decider ledger contract

`verify-notify` reads the decider's tables in `/var/lib/hydra/credit-review/ledger.sqlite3`
(schema owned by `credit_review/decide.py`) with the same query as `decide.run_approvals`:
`decision_outcomes(id, run_id, at, request_id, action, outcome)` rows with
`action='approve' AND outcome='approved'`, joined to `decisions(run_id, request_id,
profile_id, track_id)` on (request_id, run_id). `--run` filters on the run, and
`--since-hours` on `decision_outcomes.at`. A `revert` or `support` outcome is never a
candidate, and the admin re-read drops anything no longer approved. If the tables are
missing, the decider has not run yet and there is nothing to do. If a required column is
missing, the contract is broken: the run fails loud and sends nothing.

## The gate (`scripts/intercom-verify-request.sh`)

A copy of the `intercom-ops-write.sh` gate for `POST /messages`:

- Caroline (`5763097`) is pinned, and test seams are refused on a deployed copy.
- `--approved-by` must be the captain (`U7RP6HKUZ`). The `approval_ref` (his 22:12Z words)
  is pinned and recorded with every send.
- The copy is fixed (Fable's final copy, single and multi-credit variants). The caller
  passes only first name, role, track title and artist name, in a JSON file so the email
  never shows up on argv. Every field is HTML-escaped. The rendered text gets the same leak
  check as a customer-facing ops reply, plus an em-dash check. A title such as
  "Ticket to Ride" is refused on purpose: fail closed.
- The recipient is the one Intercom user whose email equals the account email. Zero users,
  a lead only, several users, or an `external_id` naming another Muso user is a refusal.
  **The primary key is `users.neptuneProfessionalId`** (firstmate 090). It is the JWT
  `professionalId` the web app boots Intercom with (web-credits `plugins/intercom.plugin.ts` and
  `core/helpers.ts` `getUserData`), so it is what Intercom stores as the contact's
  `external_id`: never null, unique, and equal to the Auth0 subject for Auth0 accounts (all but
  7). Legacy accounts with no Auth0 subject (about 32%) are matched by it too. The credits file
  carries it as `user.professional_id`, plus the Auth0 subject as `user.auth_id` when there is
  one (firstmate 083). An `external_id` names this account when it is `professional_id`, or
  `auth_id` with or without `auth0|`; the bare numeric user id does NOT (refused as another
  account). A note that carries no account Intercom identity (neither `user.professional_id`
  nor `user.auth_id`; a bare `user.id` is not enough, #1298 / firstmate 120) is refused, except
  removal-notice (its recipient is the profile's claimed workspace email). Every driver reads both from the replica (Trino, read only; `send_all` does it for
  the verify-notify drivers (the verify-live run does it before the day's cap, so a held user's
  credits are deferred, not dropped) and `audit_documents` for the read-only `--doc-check` audit; the
  credit-retro take-back preflight and `notify` do it for the take-back notice, and withhold a
  user without one as `no_professional_id`) and holds a user with no professional id (report
  `no_professional_id`, never handed to the gate); nobody is held for a missing Auth0 subject.
  When the account email matches several Intercom users, the ONE whose `external_id` is this
  account is the recipient; none or several of them is refused as before (firstmate 091).
  A contact with no `external_id` at all is refused on every path, the in-thread legacy-id
  match included: "the Intercom user for this email has no external_id, so it cannot be matched
  to this Muso account" (firstmate 085, 090; re-checkable for the status notes and email-changed,
  terminal for the other campaigns).
- The ledger (`credit_review/verify_ledger.py`, tables `verify_messages` and
  `verify_requests`) is claimed BEFORE the api-log and the POST:
  - each request id is notified at most once;
  - one note per account per UTC day. Credits approved after today's note get no row, so
    tomorrow's digest picks them up;
  - curl failures and unverified responses stay `attempted`. They are never re-sent
    automatically;
  - only an Intercom `error.list` (`rejected`, nothing delivered) is retried, at most 3
    times;
  - refusals are terminal (`refused`, with the reason).
- The response must be an `admin_message` of the requested type with a numeric id (an
  in-thread note is checked as a Caroline comment instead; see In-thread delivery below).

`tag-proof --message-id <id>` acts only on a note this gate sent. The conversation's
`source.id` must be that note (an in-thread note must be a Caroline part of the conversation,
and only parts after it count). Only parts authored by the contact we wrote to count, and
the reply text is never extracted. ANY such reply (text or attachment) records the latest
reply's time on that message (`last_reply_at`; `REPLY RECORDED` for each newer reply) and
`extension_requested_at` on the note once: the user may be asking for
more time, so the note's credits are held from removal for a human, and the run summary
says so. A reply carrying attachments also gets the `credit-proof` tag (a claim-proof-ask note's
reply gets `claim-proof` instead; see the claim proof ask section below). A tagged thread is
never re-tagged (`ALREADY TAGGED`), but while its windowed note still has a credit no
accepted review cleared (awaiting review, or rejected) the sweep keeps reading it and
recording new replies, so a reply after any note in the thread holds that credit's removal
for a human. Nothing else
happens: no reply, no decision, no credit change. The Ops
document step (T07) picks tagged conversations up later.

Caroline's guidance for replies to these notes lives in
`workspaces/support/reference/credits-and-profiles.md` ("Credits Added on Trust"): thank
them, "we'll check it, usually within a few days", never decide.

**Rebase notes (2026-10-21).** This branch replaces some blocks from main (#1295, #1298) on
purpose. `AuthLookupError`, `account_auth_ids` (its
`coalesce(neptuneprofessionalid, auth0userid)` fallback into one `user.auth_id`), `AUTH_LOOKUP`,
`attach_auth_ids`, `Report.no_auth_users` and the `auth_lookup=` parameter of `verify_notify.run`
are replaced by `account_identities`, `IDENTITY_LOOKUP`, `attach_identities` and
`Report.no_professional_id`. These read `users.neptuneprofessionalid` and `auth0userid` as two
separate columns and pass them as `user.professional_id` and `user.auth_id` (firstmate 090, 118,
120). `run_wave`'s pre-send `attach_auth_ids` call moves into `send_all`, and `audit_documents`
does the same lookup for the read-only `--doc-check` audit. The refusals #1295 and #1298 added are
all kept: a note with no account identity, a bare numeric `external_id`, an empty `external_id`,
and the take-back identity hold (`no_professional_id`, where an unreadable replica means no run).
`CREDIT_VERIFY_AUTH_LOOKUP_CMD` (`verify_notify.AUTH_LOOKUP_CMD`) still overrides the command the
identity lookup runs (default `/opt/hydra/scripts/trino-query.sh`).

The other files the rebase check flags replace main's lines on purpose too:

- `credit_retro/takeback.py`: `_auth_ids` becomes `account_identities` (the same
  `verify_notify` lookup), and the hold reason `no_intercom_identity` becomes
  `no_professional_id`. An unreadable replica still refuses the whole run. The removed-notice
  path now also needs a professional id.
- `credit_review/verify_ledger.py`: `ASK_CAMPAIGNS` gains `uvn-status`. The `takeback-notice`-only
  exemption becomes `NOTICE_CAMPAIGNS`. Only an ask counts as "already asked" (firstmate
  063/064); before, any note did.
- `intercom-verify-request.sh`: the fixed `email` message type becomes email or in-thread
  comment. The campaign list and `--copy` list grow. The tag-proof check also accepts a thread
  that holds our note as a Caroline part. The `user.auth_id` comparison becomes `ext_is_account`
  (professional id, or Auth0 subject with or without `auth0|`). The no-identity and empty-`external_id`
  refusals are kept. Several Intercom users on one email are still refused, unless exactly one
  of them has this account's `external_id`.
- Tests (`intercom-verify-request.bats`, `test_credit_retro.py`, `test_credit_verify_notify.py`):
  fixtures move from `auth_id:"pro-42"` to `professional_id`. The `account_auth_ids`,
  `AuthLookupError` and `no_auth_users` tests become identity tests of the same refusals and holds.
- The "dropped" commits (e69c0bdb..ff55d231) are the pre-rebase head of this branch. Their
  content was re-applied as 40f97bb2 and the commits after it. The only lines missing from the
  current tree are earlier versions of code that later commits rewrote. Checked against the old
  head ff55d231 (QA @3258c41): the weekly refusal re-check and third-refusal flag (f1301bf2) are
  still wired (`uvn_status.run` and `withdrawal_confirm.run` call `verify_notify.flag_refusals`
  for `RECHECKABLE_REFUSALS`; `MAX_REFUSALS = 3`), and its four tests are still in
  `test_uvn_status.py`. Every test in ff55d231's `test_uvn_status.py`, `test_credit_retro.py`,
  `test_credit_verify_notify.py` and `intercom-verify-request.bats` is still present, except four
  Python tests and two bats tests that main itself removed in 32f2b7bd (the verify-live enable PR).
- A pending request with a blank title, artist or role, a field over the gate's caps (role over
  120 characters, title or artist over 200) or a malformed profile or track id is left out of the
  note and the rest is sent (firstmate 166, 2026-10-23; it replaces the whole-user hold of
  QA @4688346, which let one bad row stop the note). The left-out request stays pending in core
  and is reviewed, and is counted in `rows_held` when the note is sent (or, on a dry run,
  validated). The note is one per user, ever, so this campaign does not ask about it again: a later
  run that still lists the user records it as skipped in the ledger (firstmate 169). Only a user
  with nothing showable is held (`incomplete`).
- A uvn-status user with a pending request the list does not carry yet is held (`unlisted`) until
  a rebuilt list names it, so the one note never leaves out a request opened after the list was
  built (QA @3258c41). The same rule (`uvn_status.plan`) runs again on the fresh replica read
  right before each send, so a request opened between the batch and the send holds the user too
  (QA @1f59d68), and a request blanked in between is left out of the note.

## Operate

- Dry run (validates every note, sends nothing): `python3 /opt/hydra/scripts/credit-review.py verify-notify`
- Kill switch: `touch /etc/hydra/credit-verify-notify.disabled`, or set `enabled: false` on
  `credit-trust-verify-notify-15m`. It stops verify-live (`verify-notify`) and its waves only.
- Ops notes kill switch (firstmate 117): `touch /etc/hydra/credit-ops-notes.disabled` (override:
  `CREDIT_OPS_NOTES_KILL_SWITCH`) stops `uvn-status` (and the status notes it sends),
  `withdrawal-confirm`, `email-changed`, `claim-proof-ask` and `claim-status`: they print `NO_REPLY` and nothing runs. The
  verify-notify switch does not stop them, and this one does not stop verify-live.
- Replica shape: `credit_requests.credits` reaches Trino as a varchar holding a Postgres `text[]`
  literal (`{Mixing,"Mastering Engineer"}`), parsed in Python (`verify_notify.pg_text_array`;
  Trino cannot `CAST` it to `array(varchar)`). Any other shape reads as no role: the request is
  left out of the uvn-status note (the user is held, `incomplete`, only when nothing else is
  showable) or refused (withdrawal-confirm), and the first one
  per run is written to the credit-review run log.
- Titles: a track title that already starts and ends with its own quote marks (`"` `“` `”` `„` `«` `»`
  `'` `‘` `’` `‚`, e.g. `„glücklich“`) is shown as it is, never wrapped in our quotes again, in
  every campaign (firstmate 118 b); credit-retro's take-back preview follows the same rule.
- What was sent: `sqlite3 /var/lib/hydra/credit-review/ledger.sqlite3 "select day,status,message_type,n_credits,message_id,reason from verify_messages order by id desc limit 20"`.
  The api-log entries are `intercom-verify-request-*.json` and `intercom-tag-*.json` under
  `/opt/hydra/workspaces/operations/api-logs/`.
- To re-open a refused or stuck (`attempted`) request, delete its `verify_requests` row.
  The next run offers it again.
- Schema: every deploy runs `verify_ledger.py --db /var/lib/hydra/credit-review/ledger.sqlite3
  migrate` (Step 5a, warn-only), which creates or upgrades only the `verify_*` tables in the
  ledger it shares with the decider. credit-retro's take-back gate reads `verify_messages`
  (columns pinned as `verify_ledger.READER_COLUMNS`); `scripts/tests/test_verify_ledger_contract.py`
  keeps the writer and that reader in agreement.

## Band A gets no note (Fable ruling 2026-10-22 23:10Z on firstmate 095)

Core stamps every automation approval `provisional` with a `proofDueAt`, band A included. The sender keys on `metadata.approval.anchor_kind`, not on the provisional flag:
- **`anchor_kind = trusted` (band A):** no document ask; the user gets only core's standard "approved" notice. `verify_notify.screen_live` closes the row in the verify ledger, so it is never offered again, never reminded and never removal-due. The run report counts these as "band-A approval(s) on a trusted anchor".
- **Any other value (band B):** the verify note as before.
- **The decider-side filter stays as a second guard:** `decisions.evidence_kind = validator_low_risk_trusted` never becomes a candidate.

Owners: cmux-credit-system-lane pins `anchor_kind` in core, credit-trust-llm-t01 owns the L7 expiry skip, and the board keys its countdown on `anchor_kind`.

## Never ask someone who already sent documents

Captain standing order (verbatim): "make sure you arent asking for things from users that
already submitted documents and we approved. dont piss anyoen off". Every ask passes these
filters, and when in doubt nothing is sent. New credits must still never escape the 30-day
rule silently, so for them the documents rule is per CREDIT:

1. **Proof-on-file list** (`/var/lib/credit-trust/proof-on-file.json`, the same exclusion
   the decider uses; owner the credit-system lane, refreshed hourly; entries
   `{user_id, request_id|null, kind}`, kinds `approved_doc`, `pending_doc`,
   `human_approved_after_doc`). The list is authoritative only when it is complete: a
   non-empty `sources[]` with every required part usable (`scripts/credit_review/proof_parts.py`,
   shared with the take-back gate and, in TypeScript, Caroline's support tool
   `plugins/support-tools/src/tools/proof-on-file.ts`; one fixture file,
   `scripts/tests/fixtures/proof-parts-contract.json`, pins both): `core`, `cs-intercom` (only the exact legacy label
   `cs-systemic intercom+gmail` is read as Intercom, and as Intercom only) and `cs-gmail`
   (documents emailed to support@), each present once, not flagged `stale`/`missing` (any
   truthy value) and carrying its OWN fresh timezone-aware `generated_at`; no other
   part flagged stale or missing; and
   `users` equal to the distinct user ids in `entries[]`, and every entry well-formed (a
   malformed row is never skipped: it refuses the whole file). A missing, unreadable, older-than-3h,
   future-dated (beyond 6 minutes of clock skew, file or any part) or half-written export makes the run send **zero** asks and exit non-zero, in both
   campaigns (`--proof-on-file FILE` overrides the path).
   - **Gmail (`cs-gmail`):** while it is missing or stale nobody is asked, reminded or
     made removal-due: a snapshot of who emailed support@ cannot cover mail sent after it,
     so no contact list narrows the hold. The live export does carry `gmail_contacts_90d`
     (`{generated_at, source, user_ids[]}`); every reader accepts a file with it and
     deliberately ignores it.
   - **The decider does not follow this rule yet:** `decide.py` only refuses a part with a
     truthy `stale`/`missing` flag; it neither requires `cs-gmail` nor checks each part's own
     `generated_at`. It must import `proof_parts` (credit-trust-llm-t01 owns that switch);
     until it does it lacks the `cs-gmail` rule.
   - **Past credits (`retro-past`):** a `user_id` listed with ANY entry is never asked, and
     their credits are closed as `skipped`.
   - **New credits (`verify-live`, the note and its day-14/day-25 reminders):** a credit with
     an entry for THAT request id (any kind) is not asked about (closed as `skipped`; left
     out of a reminder). If the user has a `pending_doc` entry on another credit (or a
     whole-user `pending_doc`), the whole user waits: nothing is sent or closed, and each
     credit gets a `deferred_pending_doc` row in `verify_requests` (request, profile and
     track ids, first deferral time). That row blocks nothing, uses no daily message and is
     never removal-due; every later run re-reads it whatever its age (the 168h
     `--since-hours` window applies to decider approvals only). Once that document is
     reviewed (the entry is gone) the user gets ONE batched windowed ask with any new
     credits; the row becomes the note's, or `skipped` when the credit has its own document,
     was approved by a person or is no longer approved on the server. The first deferral
     time stays on the row, so if Intercom rejects that ask (`rejected`, retries left) it is
     still offered on later runs, whatever its age. The report counts the waiting accounts
     and credits. The cron's removal-due count is a ledger read (no admin calls); only the
     `--removal-due` export re-reads for human approvals. `approved_doc` / `human_approved_after_doc` entries on other
     credits, and whole-user identity documents, are no reason to skip or wait.
2. **Human approvals.** A request whose `metadata.approval.isAgent` is false was approved by
   a person. We cannot tell which of those saw documents, so none is asked about (initial
   notes and reminders).
3. **Intercom check at send time** (in the gate, **past credits and `uvn-status` only**). If any conversation
   of the recipient holds a document the USER attached (in a reply, or in a conversation
   they opened), or is tagged `credit-proof`, the note is skipped and its credits are
   closed. Email replies land in Intercom, so this covers both channels. A contact with
   more than 150 conversations counts as "sent". A failed read sends nothing and claims
   nothing. `--doc-check` runs this check read-only for `--campaign retro-past` and never
   claims or sends; it is refused for any other campaign or kind. A new credit's note is
   never skipped for a generic Intercom attachment or a long conversation history.
4. **No repeats.** A credit asked about in any ask campaign is never asked about again. A
   past ask goes at most once per user, ever (any earlier ask counts), and messages are
   always batched per user. Only the ASK campaigns count as "already asked": `verify-live`,
   `retro-past`, `uvn-status` and `gap-ask` (the gap ask itself is blocked only by its own rows: see the stage-2 release below). A notice or confirmation (`withdrawal-confirm`,
   `takeback-notice`, `removal-notice`, and merge outcomes, which are not in this ledger)
   never closes a user's asks (firstmate 063/064).

Before/after counts on node-8, read-only: `credit-review.py verify-wave --mode dry-run
--wave-file W --max-users 1000 --audit-docs /tmp/audit.csv`. The report gives the counts for
filters 1-3, and the CSV lists `user_id,credits,result` with no emails.

## Two variants: new credits vs past credits

Captain, 2026-10-15 23:40Z: "if no valid verification comes it should be removed". Narrowed
2026-10-16 00:35Z: "how many credits were approved without documentstion i dont want to lose
users unless its obvious fraud feom tbe past". So a removal date is only ever stated, and a
credit is only ever removal-due, for NEW provisional approvals. Past credits are asked
without a threat, and proven fraud is removed by its own take-back path, never by these
notes.

| | NEW provisional approvals (`verify-live`) | PAST credits (`retro-past`) |
|---|---|---|
| Copy | `windowed`, the only copy ever sent: Fable's v1 with ONE date, the reply-by date 30 days out ("Reply to this message by {reply_by} (30 days from today)", "If we can't verify this credit by {reply_by}, it will be removed from your profile that day"), and a restore line ("If you send a valid document after that, we'll review it and can restore the credit"). The ledger stores `due_day` = reply-by and `removal_day` = the day after it, so nothing is ever removed before the date the note named. The day-25 reminder adds "If you need more time, tell us which credit and why, and we will keep the request open." (Fable copy review 2026-10-17, pack 1). `v1` (no date) is preview-only | Fable's GO'd role drafts: routine review, one document per credit, **no deadline, no removal language** |
| Follow-ups | day 14 and day 25 (the second says it is the last), only for credits no review has ruled on. A **rejection sends nothing from this script** (see below). A follow-up with nothing left to send (every credit documented, approved by a person or no longer approved) is closed as `skipped`; one whose user is waiting on a pending document stays due. Only follow-ups actually sent count against `--max-users` | **none**: one message per user, ever, and never to a user who already sent proof |
| No reply | windowed: `credit-review.py verify-notify --removal-due FILE` lists the credits from their `removal_day` (00:00Z after the reply-by date ends; a reply on the reply-by date is never already in the export), minus any with their own proof-on-file entry (any kind) or a human approval. Credits whose user replied to the note are held for a human and written separately to `FILE.held`, never to FILE. A missing or stale proof-on-file list exports nothing and exits non-zero | the credit stays; `credit-review.py verify-wave --unverified FILE` lists it as `unverified` for the board / valuation basis after 30 days |
| Send lock | `LIVE_WINDOWED_COPY_APPROVED=0`: every real verify-live send is refused, and the cron ships disabled | `RETRO_COPY_APPROVED=0`; cron ships disabled |

- Each lock flips in a PR that carries Fable's GO and the captain's approval of the
  rendered copy. `--dry-run` renders everything: `--copy windowed` previews the new-credit
  copy, and `--campaign retro-past` the past one.
- A note records whether it named a removal date (`removal_day` in `verify_messages`).
  Only such a note can be removal-due, and only from its own `removal_day`. Because v1 is
  never sent, every new credit that gets a note has a removal date.
- Removal is decided PER CREDIT. A note with a proof reply (tagged `credit-proof`) waits for
  the document review. The review records a verdict per credit with `credit-review.py
  verify-notify --proof-review <message_id> --request-ids r1,r2 --outcome accepted|rejected
  [--reason R] --reviewer <who>` (`verify_proof_reviews`, keyed by the note and the request
  id). **Only an accepted document clears a credit.** When a document (attachment) was received on
  the note, a rejection needs `--reason`, one of `doesnt_name_you`, `other_track`,
  `other_role`, `unreadable`, `not_a_document`; the reason is for humans - it stays in
  `verify_proof_reviews` and the audit file and **reaches the user in no message** (never the
  file name, never a reason). After a reply with no document a rejection takes no reason. Once every credit on the note is
  reviewed and any was rejected, the note goes back to "no proof" and the sweep re-tags it
  only when a NEW attachment arrives (which puts every rejected credit back under review).
  A reviewed credit never gets a day-14 / day-25 reminder ("We haven't received a document
  yet" would be false).
- **After a rejection NOTHING is sent by this script** (deleted 2026-11-04, Fable ruling-79
  denial + dispatch `decline-copy.md` + Aaron 2026-10-29 wording rule). The kind, its copy and
  its five fixed reasons (`doesnt_name_you`, `other_track`, `other_role`, `unreadable`,
  `not_a_document`) are gone from `intercom-verify-request.sh`; `--kind after-rejection` is
  refused. The old copy named ONE of those five, i.e. it told a forger exactly which check
  failed and over-communicated on a decline. The decline is the single approved sentence in the
  `decline` campaign (its own PR), sent once per decision, with no reason, no deadline and no
  list of accepted documents. `verify_ledger` keeps the historical kind for reading old rows
  but `reminders_due` no longer offers it.
- **A reply after a note** (text or attachment; the latest user reply's own time is recorded
  per message, `last_reply_at`) holds the credits that note named for a human until a review
  rules on them again.
- **Held for a human** (`FILE.held`, counted in the run summary, never in FILE), each with its
  reason: a credit past its date whose document still awaits review (`document awaiting
  review`, including a credit the reviewer never ruled on), a credit whose user replied to the
  note in any way and no review has ruled on (`extension_requested_at`; the run summary also
  reports each newly recorded reply), and a rejected credit whose user replied after the note.
  A human picks them up with `--proof-review`.
- The removal export removes nothing. The removal step (a guarded server soft-remove with a
  restore path) must re-check each credit and never remove one that was confirmed
  meanwhile.

### Past-credit waves

- **Population: genuine risk only** (firstmate 2026-10-16 after the captain's 02:00Z "are you
  annoying people fornbackup that we shpuldnt be?"). The wave file is the population: the
  retro review's HOLD tiers, the velocity accounts and the contradicted or unverifiable
  big-track rows, about 320 users. The 13K+ small unverifiable, established-footprint,
  web-credible and trusted-confirmed credits are left alone and flagged internally only.
  `--exclude-users FILE` (one user id per line) leaves out accounts whose existing credits
  are handled elsewhere.
- **Wave file:** `/var/lib/hydra/credit-review/waves/retro-past.csv`, CSV with
  `credit_request_id,user_id,profile_id` required and
  `track_id,tier,pop_now|pop_at_claim,paid,claim_date` optional. Rows are merged per
  request, so the tiers file's one row per role works as is. Without a `paid` column,
  nobody is treated as paid.
- **Tick:** `credit-review.py verify-wave --mode apply --wave-file ...` (cron
  `credit-past-verify-wave-15m`, shipped **disabled**). Each tick does two things:
  - **Initial notes.** It picks the next users (paid first, then users with a big track at
    pop >= 60, then the oldest claim) within `--max-users` per run and `--daily-max-notes`
    per UTC day, sent `--pace-seconds` apart. It re-reads those rows and announces only the
    ones still approved. Rows that are no longer approved, or cannot be announced (no account
    email, title or artist), are closed as `skipped`, so they never take a slot again. Each
    user gets one note listing all of their credits, big tracks first (the first 100 are
    listed, then "and N more"). A user who already had a past-credit note, or who already
    sent proof on any note, is skipped.
  - **Proof sweep.** The same `tag-proof` sweep `verify-notify` runs (see the gate above).
- **Preview:** `--mode dry-run --preview DIR` writes every rendered note (0600) for review.
- **The cap is shared:** one message per user per UTC day across both campaigns and all
  kinds.

## Take-back notices (`--campaign takeback-notice`)

- **Caller:** `scripts/credit_retro/notice.py` (`credit-retro.py apply` / `notify`, #1237/#1242), when a proven take-back of a past credit executes. The gate only renders, checks and sends.
- **Copy:** fixed, verbatim from `docs/credit-verification/retro-drafts/takeback-notice.md`; a bats test diffs the gate's rendering against `notice.render`. Which credit and role, who the public credits name (only the names in the recorded evidence), the source label (`public credits page`, `Spotify credits`, `Tidal credits` or `Spotify and Tidal credits`) and a public https link (plus an optional `corroboration_url`, cited as "; also named in …" and refused unless it is a public https link of at most 300 characters other than the evidence link), and how to dispute with one document. One line per title + artist + role, up to 25 listed. No date, no follow-ups.
- **Lock:** `TAKEBACK_COPY_APPROVED=0` until Fable's copy GO and the captain's approval. While locked, `--validate` refuses (exit 1, so `credit-retro apply` removes nothing) and only `--dry-run` renders the copy. Unlocked, `--validate` exits 3 when the user already had a message from this gate that UTC day (one message per user per day across all campaigns).
- **Removal notice vs take-back notice:** `takeback-notice` is sent by the take-back run itself, at removal time. `removal-notice` is for removals made some other way (staff deletes, with a reason per credit, incl. the backfill). The two are keyed differently (credit request id vs removal event id), so the ledger does not dedupe across them: a `removal-notice` events file must leave out removals that `credit-retro` made, since their owners already got a take-back notice. A take-back notice is not an ask, so an earlier `verify-live` or `retro-past` note about the same request never blocks it; only its own `takeback-notice` rows do.

## UVN status reminders (`--campaign uvn-status`) and withdrawal confirmations (`--campaign withdrawal-confirm`)

**Authority.** The captain's standing order, 2026-10-19 17:24Z, verbatim: "are you properly communicating to everybody that's making credit request and also are you figuring out how to do profile merges that are being requested by Caroline as well make sure that you have all of the operation functions that Jan performs under your watch. I still want the guard up, but I want you to do everything based off of the research that you do and also your communications with the actual users." Under it, firstmate approved the uvn-status copy (inbox 060) and the withdrawal-confirm template (inbox 061), and confirmed both on 2026-10-19 (inbox 064). Every note of either campaign records that order and approval as its `approval_ref`.

- **uvn-status** (Fable ops-takeover section 2 class 2; copy approved by firstmate 2026-10-19 21:07Z): one status + reminder per user whose credit requests wait on them (`user_verification_needed`), ever. It is an ask.
  - **Driver:** `credit-review.py uvn-status --list <newest dated uvn-reminder-list.json from credit-trust-llm-t01> --segment paid|free --mode apply --max-users N`. Canary: `--max-users 3`. At most 400 per UTC day. Kill switch: `/etc/hydra/credit-ops-notes.disabled` (see Operate). A dry run's `--preview DIR` writes one file per user, named by the Muso user id (`<user id>.txt`).
  - **Budget:** users the ledger already answers for (listed requests noted or closed, already sent, proof received, messaged in 7 days, asked in the last 90 days by any ask campaign) are dropped before the per-run budget is spent, so repeated runs keep reaching new users. A real run closes the ones done for good, no longer waiting, or without an account email. The 7-day and the 90-day one-ask lock are deferrals: nothing is closed and the user is offered again once they lapse (the run reports them as "deferred (messaged in the last 7 days or today)" and "deferred (asked in the last 90 days)"). Users the gate defers for a recent message in Intercom do not use the budget either: the run keeps going past them, at most 5 gate calls per budgeted user. For the status notes (below), a gate refusal does not use the budget either; it counts toward the same 5-calls-per-user cap and follows the 7-day re-check / 3-strikes rule. The hold is found by the account email OR the Muso user id, so an email change neither frees the user early nor resets the strike count. A pending request with a blank title, artist or role, a field over the gate's caps (role over 120 characters, title or artist over 200) or a malformed profile or track id is never shown: it is left out of the note and the rest of the note is sent (firstmate 166). It stays pending in core and is reviewed, and is counted in `rows_held` ("request(s) left out of a note") when the note is sent or, on a dry run, validated; a deferral, refusal or skip counts nothing. The note is one per user, ever, so this campaign does not ask about it again: a later run that still lists the user records it as skipped in the ledger. Only a user with nothing showable is held (`incomplete`, not closed) and re-checked on the next run, once a field is fixed. A request still waiting on them that the list does not carry (opened after the list was built) holds the user the same way (`unlisted`, not closed) until a rebuilt list names it; a request the note would never ask about (approval path, already on the profile) does not.
  - **Re-checked before each send:** the list is at most 30 h old (re-run `build.py` the morning of a send day); the strict proof-on-file rule (any entry = no ask; UNKNOWN = nothing sent); the request is still UVN on the replica (Trino, never admin paging), and the `incomplete` / `unlisted` holds are applied again on that same read; in the gate, documents attached or tagged in Intercom = skip, any admin or Caroline message in 7 days = defer (a conversation we opened counts only when it was opened in those 7 days), the ledger (one per user ever, 7 days, one message per user per day, and the one-ask-per-user-per-90-days lock across verify-live, retro-past and uvn-status: a deferral, nothing closed, the gate answers `DEFERRED recently-asked`).
  - **No second ask** (Fable via firstmate 094, narrowed by firstmate 102): the replica re-check leaves out a request whose `verificationData.duplicate_of` is set (already on the profile, firstmate 086) or that the approval path can actually admit (it sends one v1 note): ALL of validator-approved (`is_approved`), `total_risk_percent` < 30, track popularity 1..59, for a one-person role no trusted source crediting it to someone else (`rule_risk_percent.review_role_credited_to_other_at_trusted_source` 0 or absent), and no server proof reason (`policy.server_proof_reasons`, the mirror of core's agent-approval guard) other than a band-hint-only stamp. A missing or unreadable field never leaves a request out. The run reports `already_on_profile` / `approval_path` (no ledger row: they leave the list once approved) and `low_risk_asked` (validator-approved, risk < 30, but the server needs proof: asked as normal); the note names only the remaining requests, and a user with nothing left to ask about is not messaged.
  - **Delivery:** in the user's most recently updated OPEN conversation of the last 14 days when there is one, otherwise email (see in-thread delivery below). A conversation the gate picked that fails a check (another contact, a human assignee, a do-not-message tag, unreadable) is dropped and the note goes by email: nothing is refused and the ask stays open (firstmate 066). A failed or unverified lookup of the open conversations sends nothing and claims nothing; the next run tries again (firstmate 071).
  - **Copy:** up to 3 titles, then "and N more". One request with several roles (role text `Mixing, Mastering`) asks for "something that shows your Mixing and Mastering credits" (roles joined with ", " and a final " and "); one role stays "your Mixing credit" (firstmate 118 c). The list sentence is Caroline's Step 2 ask marker, so her ask-once guard counts this note as an ask.
- **withdrawal-confirm** (firstmate 2026-10-19 21:21Z): the fixed "We've withdrawn your credit request for {role} on "{title}", as you asked" note. Role and title come from the request row. Not an ask: it never closes a user's asks.
  - **Sent only for a requester withdrawal:** the row is `rejected` with `metadata.withdrawal.by = requester`.
  - **Once per request:** enforced by the ledger.
  - **Command:** `credit-review.py withdrawal-confirm --request-ids <id>[:<conversation>],... --mode apply`. An id with a conversation is answered in that conversation; a bare id goes by email. Kill switch: `/etc/hydra/credit-ops-notes.disabled`.
  - **Exit status** (firstmate 088): 0 = every requested confirmation was sent or already sent; 3 = at least one is held or deferred (a confirmation not sent is a promise we did not keep, so it must be visible: the report lists each such request id with its reason, `<id>: held, no professional id on the account` or `<id>: deferred, daily cap: retry tomorrow`); 1 = a refusal or failure.
- **In-thread delivery** (firstmate 063): `intercom-verify-request.sh send --conversation <id>` (uvn-status, withdrawal-confirm, the status notes and email-changed). For an explicitly passed conversation, the gate reads it (an unreadable one sends nothing and claims nothing) and refuses (nothing sent; recorded; for the status notes and email-changed as a 7-day re-check hold) unless its one contact is the Intercom user resolved from the account email (for email-changed, the contact linked to the account id), it is not assigned to a human, and it carries no do-not-message tag (`abuse-block` or a social/SMS channel tag). A closed or snoozed conversation is fine: the reply reopens it. It then posts a Caroline comment (`POST /conversations/{id}/reply`, admin 5763097, the rendered HTML, no subject), checks that the answer's last part is that comment, and records it like an email note (message id = the part id, plus the conversation id). `tag-proof` accepts such a note and counts only the user's parts after it.

## Stage-2 release: the gap ask (`--campaign gap-ask`) and no_document users on uvn-status

**Authority.** Fable's ruling 2026-10-26 13:23Z (firstmate `captain-asks-fable-r4` report section H, GO 2) under the captain's 12:40Z order ("Fable decides, do not ask him"): of the 512 paid users held as "proof on file", the 43 stage-2 `no_document` users get the already-approved uvn-status copy and the 460 `need_more` users get a dated gap ask with Fable's exact paragraph, one per user per day, no deadline, no removal words. The drain that measured it: firstmate `data/verification-drain-d2/report.md` section 1a.

- **The release** (`scripts/credit_review/stage2_verdicts.py`, read-only over the proof store's `stage2_shadow`): a request is released when the latest verdict, under the current analyzer version, of EVERY claimed role is the campaign's outcome (`need_more` -> gap-ask, `no_document` -> uvn-status). An account with any `reject_hold` or an account-level `human` hold is never messaged. A request stage 2 did not judge, or judged anything else, keeps the proof-on-file hold: a document on file still excludes the user unless every credit the note would ask about is released, and an APPROVED proof entry (`approved_doc` / `human_approved_after_doc`) that names the credit always excludes it. A whole-user approved entry (it covered another credit) does not. An unreadable store releases nothing.
- **The decider** keeps released requests held (never a support write: its Knock notice is a generic re-ask outside this ledger's one-message-per-day rule) and labels them `proof on file: stage 2 judged the document (<outcome>): the user is asked through intercom-verify-request.sh --campaign <campaign>`, counted as "handed to the stage-2 ask" in its run line.
- **Driver:** `credit-review.py uvn-status --from-stage2 --campaign gap-ask|uvn-status --segment paid|free --mode dry-run|apply --max-users N [--exclude-users FILE]`. `--from-stage2` builds the population live from the store (no list, no list-age gate), and a note names ONLY released requests (an unjudged request of the same user is never named). For uvn-status it also reaches released requests still `unverified` (held with us). In the gate, uvn-status's Intercom documents skip yields only when the gate itself reads `no_document` for every credit of the note for this account (same helper as gap-ask); otherwise, or with the store unreadable, the skip stands. `--exclude-users` leaves out ids another lane messages today (they are offered again on a later run). Everything else is the uvn-status runner: the replica, proof-on-file and stage-2 release are re-read right before each send, ask cap 400 per campaign per UTC day, kill switch `/etc/hydra/credit-ops-notes.disabled`.
- **The gate** (`gap-ask`): reads the verdicts itself (`stage2_verdicts.py gap-credits`, pinned to `/var/lib/hydra-credit-verify/proof.sqlite`): every credit must be released to `need_more` for THIS account (`user.id` required) and every role the caller names must be a judged role, else it refuses. The paragraph is Fable's, verbatim except its last sentence, which reads "Your request stays open while we look." (decision B, inbox 005: the asked rows are pending, not live). `<doc summary>` comes from the verdict's best document: its kind (a fixed label: split sheet, contract, invoice, letter of direction, PRO registration, distributor screenshot, streaming-dashboard screenshot, session screenshot, credits page; else "document") and up to two OTHER held titles it names (catalog titles, never document text); several documents read "documents" (or the plural label when they are all one kind). `<track> as <role>`: up to 3 pairs joined with ", " and " or ", then "(and N more of your credits)". The caller cannot supply any of it. Once per credit; not blocked by an earlier ask about the same credit or by a proof reply (that reply is what stage 2 judged); never skipped for documents in Intercom; one message per user per UTC day across campaigns; none within 7 days of another note from us (ledger and Intercom) EXCEPT the user's status-doc-received notes, the follow-up they promised ("we'll message you here as soon as it's checked"; firstmate, verify-ask-wiring-h2 inbox 003). A gap ask counts as an ask for the other campaigns (their once-per-credit and 90-day locks). In-thread delivery as uvn-status. No follow-ups.

## In-app delivery past the email cap (`--channel inapp`, `--inapp-overflow`)

**Authority.** Captain 2026-10-26 16:05Z, relayed by firstmate (verify-ask-wiring-h2 inbox 010): "Caps may pace email only; the in-app message goes to everyone."

- **Gate:** `--channel inapp` (uvn-status, the status notes, claim-status, gap-ask; initial notes only) never sends email. The note goes into the user's own open conversation when the gate finds one, exactly as without the flag, otherwise as an Intercom in-app message: `POST /messages` with `message_type: in_app`, Caroline as sender, the same HTML body and no subject. The request enum is the documented `in_app`; the response must be an `admin_message` of message_type `inapp` (Intercom's response spelling, which is also what the ledger records), or the claim is left `attempted`. The ledger records the note as message_type `inapp`, and every rule stays: once per user/credit, one message per user per UTC day across campaigns, 7 days, 90-day ask lock, recipient identity.
- **Driver:** `credit-review.py uvn-status ... --inapp-overflow` counts the campaign's daily cap (400 for the asks, 1,000 for the status notes) against EMAIL notes only. Once the day's email budget is spent, every further note is sent with `--channel inapp`. The run is then bounded by a 5,000-per-campaign-per-day sanity cap instead. Without the flag nothing changes.
- **Stage-2 undetermined** (same inbox, "undetermined -> rerun once then ask"): a role stage 2 judged `undetermined` in two runs (the first and one rerun, current analyzer) is read as `no_document`, so the request goes to the uvn-status ask (and the gate's Intercom documents skip yields to it). A single undetermined judgement keeps the hold; a later run that finds something replaces it.

## In-thread legacy-id match (firstmate 089)

Many legacy accounts have no Auth0 subject (`users.auth0userid` empty, about 32% of accounts), and their Intercom `external_id` is a UUID we cannot map. It stays as a backstop to the professional-id match (firstmate 090). For **in-thread replies only** (withdrawal-confirm with a conversation, email-changed, email-changed-dup; never uvn-status, the status notes, verify-live, retro-past, removal/takeback or any email or bulk send), when the thread contact's (non-empty) `external_id` matches neither the professional id nor the Auth0 subject, the gate still answers in the user's own conversation when ALL hold:

- the conversation has exactly one contact, an Intercom user;
- that contact's email is the Muso account email (case-insensitive, trimmed);
- the email is not a shared or role inbox: its local part (before `@`, lower-cased, without a `+tag`) is not one of info, support, help, admin, contact, hello, office, team, booking, bookings, management, mgmt, music, label, records, publishing, accounts, billing, sales, marketing, press, media, studio, noreply, no-reply, mail, enquiries, inquiries (otherwise refused: "shared or role inbox");
- the contact's `external_id` is not another Muso account. The driver asks the gate for it (read only: `send ... --conversation <id> --thread-contact` prints `THREAD_CONTACT {"contacts", "role", "external_id"}`), checks it with one replica read (`users` where the id, the professional id, the Auth0 subject, or `auth0|` + it equals the external_id) and passes `user.thread_external_id` and `user.ext_other_account` (true/false). A missing field (also when the external_id cannot be checked), or one for another external_id, refuses the legacy path. A gate refusal of the pre-flight read is reported as a refusal with the gate's reason; only a failed Intercom read reports "could not be read". An empty external_id is refused, never matched this way.

Such a send is recorded with reason `in-thread-legacy-id contact=<id> external_id=<ext>` in the ledger and as `recipient_match` in the api-log.

## Identity refusals and the fraud lens (Fable ruling-intercom-external-id-1026)

The gate's external_id rule is never loosened. A refusal for an empty or orphan external_id is fixed in the DATA
by `credit-review.py intercom-reconcile` (classes A1-A5, dry run first, ledger row before each write, `--revert`).
`uvn-status` holds fraud-lens users and keeps big-track single-signal users on the document ask only.
Runbook: [intercom-identity-reconcile.md](intercom-identity-reconcile.md).

## No-ask status notes and email-change replies (firstmate 068-073, captain standing order 2026-10-19 17:24Z)

- **`status-doc-received`** (credit-trust-llm-t01 list `status-A-doc-under-review-*.json`) and **`status-team-review`** (list `status-B-with-our-team-*.json`): one status note per user, ever, with the approved fixed texts (copy file `copy-doc-received-team-review-1020.md`).
  - **Not asks:** no proof-on-file exclusion (these users are exactly the ones with documents or requests with us), outside the 400/day ask cap (a 1,000/day sanity bound), and they never close an ask.
  - **Shared rules:** same 7-day Intercom check and in-thread-or-email delivery as uvn-status.
  - **Replica re-check** (firstmate 076): the listed requests must still be pending (`user_verification_needed`, `unverified` or `processing`, not deleted); uvn-status keeps `user_verification_needed` only. A status-note user with none left is counted as `not_pending` and never closed in the ledger.
  - **Budget:** a gate refusal does not use the run budget (like a deferral) and counts toward the cap of 5 gate calls per budgeted user.
  - **Refusals are re-checked, three strikes, per user** (firstmate 076, 082, 083): a gate refusal of a status note or an email-changed reply holds the USER in that campaign (`verify_refusal_holds`, keyed by campaign and account email and found by that email OR the Muso user id, so an email change keeps the hold and its count: reason, refusal count, `next_recheck_at` = now + 7 days), whatever requests are listed or still pending. The runner skips the user until then (reported as "refused, re-check after <date>") and the gate answers `DEFERRED refused-recheck` (exit 3). A later send clears it; another refusal adds one and holds it 7 more days. After the third refusal (21 days) the run posts it once to #cs_priority for a human (Muso user id, campaign, reason; no email; `scripts/lib/slack-notify.sh`, operations bot) and records `flagged_at`: the user is blocked in that campaign (the gate answers `SKIPPED refused-flagged`). A failed post leaves it un-flagged (retried next run) and the run exits non-zero.
  - **Command:** `credit-review.py uvn-status --campaign status-doc-received|status-team-review --list <newest list> --segment paid|free --mode apply --max-users N`.
  - **Silent hold** (Fable ruling 017, 2026-10-27): `verify_ledger.py hold-silent --user-ids-file F --reason <slug>` writes a flagged refusal hold in status-doc-received and status-team-review for each Muso user id. The runner and the gate then skip those users for good (refused-flagged), a later send never clears it, and it is never posted to #cs_priority. The uvn-status ask is not held. It was first used for the 40 users told "nothing else is needed" while they owe proof, with reason `owe-proof-told-nothing-needed`; they stay first in line for the uvn-status ask once a returned document can be accepted.
  - **Queued wording** (firstmate 092): `status-doc-received` has an approved alternative, `--wording queued` (gate `--copy queued`, recorded with its own approval ref naming firstmate 092): "Hi {name}, a quick update on your credit request(s) for {titles}: we have the document you sent, and it's in our review queue. We'll message you here as soon as it's checked - no need to send anything else." (same 3-titles-then-"and N more" rule and request/requests). The default "reviewing" wording stays. No dates.
  - **No-ask team-review wording, Copy B0** (firstmate 106, credit-trust-llm-t01 key pending-status-1021): `status-team-review` has an approved alternative, `--wording no-ask` (gate `--copy no-ask`, recorded with its own approval ref naming pending-status-1021 / firstmate 106): "Hi {name}, a quick update on your credit request(s) for {titles}: they're with our team for review. Nothing else is needed from you right now." (Copy B without its optional proof sentence; same 3-titles-then-"and N more" rule, request/requests and sign-off). The default Copy B stays. `--wording queued` applies only to status-doc-received and `--wording no-ask` only to status-team-review; any other pairing is refused by `credit-review.py`, the driver and the gate.
  - **Count-only team-review wording** (firstmate 2026-10-26 16:58Z, verify-ask-wiring-h2 inbox 005; captain 16:05Z "everyone should be communicated"): a `status-team-review` user whose listed pending requests cannot be shown (every one blank or unshowable) or number more than 1,000 is no longer held: the driver sends gate `--copy count`, "Hi {name}, a quick update on your {N} pending credit requests: they are with our team for review. Nothing else is needed from you right now." (one request: "your pending credit request: it is with our team for review."), signed "Muso Support" on email like the other status notes. It names no title, so any request may be in it. {N} is every request the replica has pending for the user at send time (re-read right before the send), not only the ones the up-to-30h list names: the note is one per user, ever, so it must not understate. `user.pending_count` carries that total, and the ledger records at most 1,000 of the request ids (the note is one per user, ever). It takes precedence over `--wording no-ask` for those users only, and applies to status-team-review only.
  - **Held for now** (firstmate 092): status A/B sends are HELD until the stage-2 proof checker is live (then they go with the default wording); if it is not live by the agreed deadline, status A goes with the queued wording.
- **`email-changed` / `email-changed-dup`**: "Done - your sign-in email has been updated ..." (dup adds the extra-account line), as a threaded reply only, once per ticket.
  - **Recipient** (firstmate 076): taken from the ticket's own conversation (`--conversation`), not the account email: it must have exactly one contact, an Intercom user (`role` user) whose `external_id` is the account's professional id or Auth0 subject (`user.auth_id`, with or without `auth0|`), or the in-thread legacy-id match (firstmate 089). Two contacts, a lead, no `external_id` or another account's `external_id` is refused. The usual human-assignee and do-not-message-tag checks still apply.
  - **Command:** `credit-review.py email-changed --user-id N --conversation C --ticket KEY [--dup] --mode apply`. It prints sent, skipped, deferred, refused and failed, and exits 3 when the gate deferred the reply (for example the user already had a note from this gate that day).

## Dated claim proof ask (`--campaign claim-proof-ask`, steers-1830 #5, firstmate 125/126)

This asks the claimant of a pending profile claim in band B or C to add the claim's bound-proof code to one platform bio by a close day. Each claim gets one note, and one day-7 reminder.

**Status:** the campaign is **send-locked again** (`CLAIM_PROOF_ASK_COPY_APPROVED=0`, captain 2026-10-27 01:1xZ): "The proof ask stays off. It offers paperwork and nothing can accept a valid ID yet." (Fable had ruled it send-as-is on 2026-10-26, firstmate 022.) The copy is Fable-approved (D38, `copy-ruling-claim-proof-ask-1022.md`), with paragraph 3 amended exactly as `claims-documentation-readiness-1023.md` ruling 1: "If adding the code isn't possible for you, reply to this message with paperwork that shows your name on one of {profile_name}'s releases: a split sheet, a producer or mixing agreement, an invoice, a royalty or distributor statement, or a PRO registration. Attach it here; we never ask for ID to claim a profile." A paperwork reply goes to document checks and a person; it never auto-approves. `--dry-run` renders exactly what would be sent.

**Copy**
- **Server facts only:** the catalog profile name and its public muso.ai link, the claim's code, and one surface phrase from the gate's fixed `CLAIM_SURFACES` list.
- **Readable surfaces only.** The phrase must name a surface claim-flow-fix-fable-c1's daily check can read, measured on 2026-10-22:
  - `spotify` renders as "Spotify artist bio";
  - `website` renders as "website (as one line in a file at /.well-known/muso.txt, or in a meta tag named muso-verify)";
  - `youtube` renders as "YouTube channel About section".

  Instagram (behind a login wall), X and TikTok (no post-link endpoint deployed yet) and anything else are refused. A claim with no readable surface waits for the documents path.
- **Spotify only:** right after the ask sentence the note adds "Open Spotify for Artists, then Profile, then About, and put the code in your artist bio." Website and YouTube get no extra sentence (Fable D38).
- **The close day:** the plain weekday and day ("Friday, November 7"), the same words in both places it appears, with no year, no time and no zone (Fable D38). firstmate 126 allowed a date for this campaign only, because it is the user's deadline, not a promise of when we act. Other campaigns keep their own date format.
- **Sign-off:** "Thank you, / Caroline, Muso Support". Email only, never in-thread.

**The close day.** It is always 14 days after the send (`verify_ledger.claim_close_day`); the list cannot set it. It is recorded as the note's `due_day`, and the reminder repeats the same day. The reminder is due from day 7 up to the day before the close day, at most once. The claim flow, not this gate, closes the claim on that day: the claim is ARCHIVED and can be reopened. A reminder dry run reads the close day from the ledger; with no sent note there it shows a day marked "(preview date)".

**Ledger.** The key is `claim-<claiming.id>`, and only `claim-proof-ask`'s own rows block it. It never counts as a credit ask, so it does not trigger the 90-day lock. The one-message-per-user-per-UTC-day cap does apply across every campaign. An admin or Caroline reply to the user in the last 7 days defers the first note and the reminder alike; a reminder deferred to the close day is never sent.

**Replies.** The daily proof sweep tags any claimant reply to the note, text only or with attachments, `claim-proof`: a queue of its own for a person, never `credit-proof`. Right before a reminder is sent, the gate reads the note's conversation itself (the sweep may not have looked lately): a reply there is recorded and tagged, and the reminder is withheld (`SKIPPED claimant-replied`); a failed read sends nothing. A tagged claim note is never credit proof: it does not close or skip retro-past or uvn-status asks. Once the claimant replies to the note at all (the claim-proof tag, or any recorded reply), the day-7 reminder is never sent: the driver closes it (`claimant replied`) and the reply waits for a person. The daily report counts claim replies and claim-proof tags apart from the credit ones.

**Driver:** `credit-review.py claim-proof-ask --list <claim-flow-fix-fable-c1 list> --segment paid|free --mode dry-run|apply --max-users N [--reminders] [--preview DIR]` (`scripts/credit_review/claim_proof_ask.py`). It is stopped by `/etc/hydra/credit-ops-notes.disabled`.
- **No send at all** unless the list names its daily code check (`daily_check.owner`) and that check ran in the last 30 hours (firstmate 126). The line "we check for it every day" must be true.
- **Sent to:** bands B and C only, with a readable platform, never a claim whose code was already found. The claim must still be `pending` on the core replica and owned by the listed user.
- **Held, not sent:** users who emailed support@ in the last 90 days are held for a person; an unreadable feed sends nothing. An account with no professional id is held too.
- **Held, not sent:** a claim whose list entry has no well-formed `profile_id` (required: the send log carries it).
- **Order:** one claim per user per run, paid first, at most 150 messages a day, first notes and reminders together. A claim already asked (a ledger row for its key that was attempted, sent, refused or skipped) is dropped before the run's budget is spent, so later runs reach new claims. `--reminders` honours `--segment` too.
- **Send log:** after each apply run, the driver rewrites `/var/lib/hydra/credit-review/claim-proof-asked.jsonl` from the ledger (`CLAIM_PROOF_ASKED_EXPORT`; a full snapshot, replaced atomically). It holds one `{id, profileId, userId, askedAt, dateClose}` line per claim whose note was sent (`askedAt` is when the note was claimed and sent; later ledger updates never move it), and the daily code check reads it.
- **`--reminders`** sends the due day-7 reminders. If the claim was decided, deleted, changed owner, had its code found or is no longer in band B/C on today's list (reclassified to A or D), the reminder is closed in the ledger and never sent. If the claim is not on today's list, the reminder waits. A 2xx conversation read with no id or no `conversation_parts` list is a failed reply check (exit 4, nothing sent), never "no reply".
- **Audience routing:** a list row with `"audience": "status"` never gets the proof ask (it gets the claim status note below).

## Receipts from the proof intake (proof loop ACK; `status-doc-received --copy queued|received`)

- **Trigger:** a `proof_intake` row (b1's filer, one per user and document, in the stage-2 proof store), not the Intercom thread heuristic. `scripts/credit_review/receipts.py` (read-only) names the intake's candidate credit requests that are still pending and splits the users:
  - users who owe nothing else go on `receipts-queued.json` and get the approved queued line;
  - users who still owe proof (any `user_verification_needed` row) go on `receipts-received.json` and get card **R1**. R1 is the queued line without "no need to send anything else" (`--copy received`, `docrecvr`). It is **send-locked** by `STATUS_RECEIVED_COPY_APPROVED=0` until the captain's yes.
- **Cron:** `scripts/paid-status/daily.sh` (node-8, 00:30Z / 15:00Z) runs the receipts stage after the segment pass, paid then free, with the segments' exclusions. R1 runs only when the gate itself says `STATUS_RECEIVED_COPY_APPROVED=1` **and** `R1_DAILY=1` is set on the cron (not set: R1 goes out in hand-run batches first, proof-loop p1); until then the run logs how many users wait.
- **Runner guard:** `credit-review.py uvn-status --wording received` halts a real run before any gate call while the lock is 0. A refusal of a status note would otherwise hold and count against the user. Each note still passes the gate's ledger (one per user, ever), the 7-day core-notice gate and the one-message-per-user-per-day cap.

## Owing-proof lines (`--campaign credit-hold-status` / `claim-proof-pending`; Fable copy-owing-proof-1027 S1/S2, SEND-LOCKED until the captain's L14a/L14b)

- **Who:** a requester who owes proof while no ask can go out. S1 (`credit-hold-status`) is for credit requests, and S2 (`claim-proof-pending`) is for a claim that needs proof. Every approved status wording says "nothing else is needed", which is false for these users, and the ask is off until a returned document can be accepted.
- **Copy:** each line is one sentence, verbatim from Fable. It says the request waits on the user, and asks them to wait for our next message before sending anything. It has no date and no ask, and never says "nothing else is needed". On email, S1 is signed "Muso Support" and S2 is signed "Caroline, Muso Support". An in-thread reply is unsigned.
- **Ledger:**
  - S1 is a once-per-user status campaign (`STATUS_CAMPAIGNS`: one per user ever, never within 7 days of another note) and a notice. It is not an ask: it never closes or counts as an ask, and an ask on the same credit does not block it.
  - S1 is NOT in `STATUS_NOTE_CAMPAIGNS`, so hold-silent does not stop it (Fable: S1 goes to held accounts too).
  - S2 follows claim-status's rules (`claim_cross_check`): one note per claim, never to a claim with a `claim-proof-ask` note, never within 7 days of another note. A claim-proof-ask waits 7 days after S2, and a claim-status note never follows S2 on the same claim (`proof_pending_sent`, closed: it would say nothing else is needed).
  - Replies to S2 are tagged claim-proof.
- **Locks:** `CREDIT_HOLD_STATUS_COPY_APPROVED=0` and `CLAIM_PROOF_PENDING_COPY_APPROVED=0`. `--dry-run` renders exactly what would be sent. The audience build and the node-8 cron wiring follow in a separate PR.

## Per-need ask (`--campaign proof-need-ask`; proof-loop captain card L11c; UNLOCKED `PROOF_NEED_ASK_COPY_APPROVED=1` on Fable [key=l11c-asks], readable + counterparty only)

- **Who:** one credit request whose returned document the reader could not check on its own. The input is b1's need tray `{user_id, request_id, need, track, role, issuer, received_at}`, mapped to one credits entry plus `need: {code, issuer, verify_code}`.
- **Copy:** the card's common opening, the line for the need code (`readable_document`, `issuer_email_from_official_domain`, `distributor_dashboard_with_code`, `counterparty_signed_or_registered`) and the common closing, signed "Thank you, Caroline, Muso Support". The text is verbatim except the issuer line's em dash, which renders " - ": the gate refuses an em dash in any note.
- **Shape checks:**
  - The issuer is a document-derived name, held to a plain-name shape: letters, digits, space, `& . , ' -`, at most 80 characters, never a domain. Anything else refuses the note.
  - The verify code is 4 to 32 capital letters, digits or dashes.
  - An unknown need code refuses.
- **Ledger:** it is an ask (`ASK_CAMPAIGNS`) handled like gap-ask (`GAP_LIKE`): once per request, ever. An earlier ask on the request does not block it, because the document came back after that ask. A gap ask on the same request blocks it, and it blocks a gap ask in turn. It may follow a `status-doc-received` note inside 7 days, but no other note.

- **Send-time state (p1 ruling 096, captain-1028-213x (c)):** the gate's go-live guards apply (G1-G5, G8, kill switch). `comm_state.py check --doc-sha --doc-at` sends it ONLY at state `checked`: a `dv_outcomes` row with a need code for that document (`proof_id` = `need.doc_sha`) on the request. It is held when:
  - anything newer arrived after the document: any later `proof_intake` arrival (even the same file), or ANY Intercom customer message or attachment after the document's own part (no slack window: the filing part itself is exactly the attachment part in the filing conversation at `received_at`);
  - each named request must have a document whose LATEST dv row is still unverifiable with THIS message's need code (a re-check that changed or settled it holds);
  - the request is decided or told;
  - any note went in the last 7 days, including Caroline in-thread. After a receipt, this makes the ask the >= 7-day "checked" follow-up.
  - A document on file never holds it, because the document is why the ask goes.
- **Delivery:** INTO `user.filing_conversation`, the document's own thread (G3: its one contact is this account's). A CLOSED filing thread sends by email instead (`R7_thread_closed`, l1); an email-filed (support@) document goes by Intercom email to the verified account contact. Never into another thread; R6 (stale) and a sorted thread hold.
- **Which document:** the unit is (user, DOCUMENT) (p1 156). Each message is about ONE document, the newest with that need, and names only that document's pending requests. It goes into that document's own filing thread, so the reply lands next to it. `need.doc_kind` / `need.doc_received_at` travel in the payload, the ledger and the dry run. The copy names it (l1 176, final): "thanks for the {image|PDF|file} you sent on {Month D} for your …"; several documents of that need sent on the newest day in one thread -> "the documents you sent on {Month D}". Kind from the mime, date = the day it arrived (server facts only; proof_intake has no real file names).
- **R9 (every campaign that delivers into a thread):** the thread must be about credits / claims / merges (ticket type, title/subject, the opening message, or one of its last 3 human parts; "credit card" does not count). Otherwise the note goes by email; for R1 / the per-need ask, comm_state then does not judge the unrelated thread. Exempt: the thread-only replies (email-changed, withdrawal-confirm).
- **verify@ is off:** `issuer_email_from_official_domain` points the issuer at verify@muso.ai. While `VERIFY_AT_ENABLED=0` (until Intercom identity verification, i2), it is HELD at send: exit 3, nothing claimed, and the dry run still renders it.
- **Unlocked 2026-10-29** (Fable [key=l11c-asks], [key=l11c-plural], [key=l11c-email-filed]):
  - readable_document and counterparty_signed_or_registered send;
  - distributor_dashboard_with_code is captain-approved (`DISTRIBUTOR_COPY_APPROVED="captain 2026-10-29 19:0xZ"`, p1 208): the universal Ctrl+F / Cmd+F form with the request's 7-day F9 code (issued at send by `credit-doc-verify.py challenge issue`; a masked `MUSO-XXXX` in dry runs), ONE credit per ask;
  - issuer_email (`VERIFY_AT_ENABLED=0`) is HELD at send.
- **Shape:** ONE message per user per need per document (newest first), counterparty first, up to 3 titles + "and N more", with the ruled plural text. It goes into the newest named document's filing thread. If that thread is closed it goes by email; an email-filed document (support@) is asked by Intercom email to the verified account contact, and only when the filing matched strongly.
- **State at send:** each named request must have SOME document whose latest dv row is an unverifiable need. A document re-checked since the cut no longer counts, and a read of another document does not cancel it. Anything after the newest named document holds the ask.
- **Source:** b1's L11c tray (`need_asks.py build --tray`).
## Claim status note (`--campaign claim-status`, Fable claims-documentation-readiness-1023 ruling 3)

The no-ask note for a pending claimant who gets **no** proof ask: holds, organizations, claims with no surface the daily code check can read, and any row the list routes with `"audience": "status"` (e.g. A-48h claims). Fable's copy, verbatim:

> Subject: Your claim on {profile_name}
> Hi {first_name}, a quick update on your claim on {profile_name}: it is with our team for review, and we will message you here as soon as it has been checked.
>
> _(Body replaced 2026-10-30 under `fable-copy-1030-r5/g`: the captain-barred 'Nothing else is needed from you right now' removed; p1 STOP on the q4 batch.)_
> Thank you, / Caroline, Muso Support

**Status:** unlocked (`CLAIM_STATUS_COPY_APPROVED=1`) on firstmate's GO after the 5-user dry run on node-8 (2026-10-26). The proof ask is locked again (captain 2026-10-27 01:1xZ); status notes go alone, paid first.

- **Channel:** in-thread when the user has an open conversation from the last 14 days (unsigned, as the other status notes), otherwise email (with the sign-off).
- **Ledger:** the key is `claim-<claiming.id>`; one note per claim, ever, with no follow-up. It is never sent to a claim that has a `claim-proof-ask` note: that claim is closed `proof_ask_sent`. It is never sent within 7 days (counted back from the send day) of another note from this gate to the same user (`messaged_7d`, deferred). The rule runs both ways: a proof ask waits 7 days after a claim-status note (`verify_ledger.claim_cross_check`). The one-message-per-user-per-UTC-day cap applies as everywhere.
- **Replies** are tagged `claim-proof` (a person), never credit proof.
- **Driver:** `credit-review.py claim-status --list <claim list> --segment paid|free --mode dry-run|apply --max-users N [--preview DIR]` (`claim_proof_ask.run_status`).
  - The list must be at most 30 hours old. No daily code check is required: the note promises none.
  - Without an explicit `audience`, a band-A or bandless row gets neither note (it is on the approval path).
  - A claim whose code was found is skipped.
  - The run uses the same replica, support@, email and professional-id checks as the ask: paid first, one claim per user per run, at most 400 notes a day.

## Removal notices (`--campaign removal-notice`)

Firstmate, 2026-10-16 15:14Z (captain-driven). Support measured that 35 owners of credits
WE removed in 30 days were never told (17 paid). Fix: owners of previously approved
credits that someone other than the owner removed get one batched email. It says which
credit and role, why, and how to dispute: reply with a document, and we'll review it and
can restore the credit. Each line states the reason first, then the action (Fable copy review
2026-10-17):

- `misattributed`: "The public credit data for {track} by {artist} lists a different person
  for {role} ({source_label}: {url}), so we've removed the {role} credit from your
  profile." `source_label` is required and must be the real source (Spotify credits, Tidal
  credits, Qobuz credits page, Apple Music credits, Discogs, AllMusic, MusicBrainz; no Jaxsta in any user-facing copy, captain 2026-10-29 03:2xZ).
- `duplicate`: the credit duplicated one still on the profile.
- `policy` with a `policy_reason` from the fixed list (`artist_by_non_artist`,
  `org_on_person`, `label_role_without_release`, `duplicate_profile`).
- **`manual_only`:** `verification`, and a `policy` removal without a sub-reason, are never
  sent automatically. A named human sends them from the board.
- A long list shows 20 lines, then "and N more".

- **Never notified:** self-removals (the owner did it), and fraud removals (silent by
  captain order, 15:48Z). The gate refuses reason `fraud`.
- **Evidence link:** a plain https URL, at most 300 characters, never an internal or Muso
  surface.
- **Per-event validation:** the driver checks every event against the gate's rules (reason
  one of the four above, `event_id` of letters, digits and dashes up to 64, evidence link as
  above, the role/title/artist length caps, no duplicate `event_id`). A bad event is left
  out and listed in the report by itself, so it never blocks the owner's other notices.
- **Not an ask:** no follow-ups, never removal-due, and the documents-on-file filters do not
  apply. Notices are idempotent per removal event id and share the one-message-per-day cap.
- **Owner:** the profile's single claimed workspace email (`docs/lessons/muso-domain.md`
  ownership rule). An unclaimed or multi-owner profile is not notified.
- **Input:** `credit-review.py removal-notice --events FILE`, JSON lines
  `{event_id, profile_id, track_id?, role, track_title, artist_name, reason, evidence_url?,
  actor, removed_at?}`, one line per removed (track, role) credit. The same command serves
  the ongoing feed (from `credit_removal_events`, once its owner exports it) and the
  one-time backfill of the 35 non-fraud owners.
- **Before anything sends:** `--mode dry-run --preview DIR --list FILE` writes the rendered
  notes and the owner list (profile ids, counts, reasons; no emails) for firstmate's
  approval. The copy is send-locked (`REMOVAL_COPY_APPROVED=0`) until Fable's GO.
- **Gap for core:** 1,072 admin removals carry no actor. The feed cannot tell those apart
  from self-removals until core records the actor.

Tests: `scripts/tests/intercom-verify-request.bats`, `scripts/tests/test_credit_verify_notify.py`,
`scripts/tests/test_uvn_status.py`.

## Enable gates (Fable decision 2026-10-17, `decision-verify-notify-enable-2026-10-17.md`)

Every gate holds the user for a human: no note, nothing closed, the credits are re-offered on
every later run (verify ledger `deferred_pending_doc` rows) and the held users are in the
daily line.

| Gate | Source | Missing source |
|---|---|---|
| Proof on file from any source (Intercom, support@ Gmail, core): no note at all | `/var/lib/credit-trust/proof-on-file.json`, through `credit_review.proof_parts` | no sends |
| Emailed support@ in the last 90 days | the same file's `gmail_contacts_90d` (`proof_parts.support_contacts`, the decider's reader) | no sends |
| Org affiliation (RULE-org-affiliation, schema `org-affiliation/v1` from cmux-credit-system-lane): a note needs verdict `none` with coverage `full`; no verdict, `held`, `labels_only`, `claimed_unverified` (automatic only for trusted-contradicted removals) or `contributor` / `verified_org` / `authenticated_domain` = human | `/var/lib/credit-trust/org-affiliation.json` (`credit_review.affiliation`, shared with the take-back gate); older than 2h or dated in the future = unknown for everyone | no sends |
| One ask per user per 90 days across the ask campaigns (verify-live, retro-past, uvn-status) | verify ledger (`verify_ledger.asked_within`, checked in the run and again at the claim) | n/a |

Cadence: once a day at 09:00 Europe/Rome, paying users first, at most 200 messages a day for
the first week (then 500), reminders included and sent first. Removal, expiry and the
retro-past wave stay disabled (`RETRO_COPY_APPROVED=0`, `REMOVAL_COPY_APPROVED=0`, no expiry
job): `--removal-due` is a manual export only.

Full affiliation checks for the next recipients: after every decider apply run (production
ledger only), `credit-review.py decide` writes the account users of every verify-notify
candidate to `/var/lib/credit-trust/inputs/org-affiliation-priority-credit-trust-llm-t01.json`
(`{"user_ids": [...]}`); the producer's next hourly run checks them with coverage `full`.

<!-- Reviewed baseline: deploy overwrites - 2026-10-27 (claim-lane-resume-c2, firstmate 035): node-8 holds the #1377-era text of this file, copied outside a deploy at 00:36:52Z; main is the reviewed text (proof ask and gap ask locked, claim status on). -->
