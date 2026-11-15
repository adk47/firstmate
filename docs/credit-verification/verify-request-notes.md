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
- `--approved-by` is either the captain (`U7RP6HKUZ`) or — since 2026-11-03, at his word ("users
  aren't in the dark ... no human reviews is the goal") — a **Fable ruling id**
  (`fable-ruling-YYYYMMDD-N`, e.g. `fable-ruling-1103-103`) for exactly the campaign+copy pairs
  that ruling pre-approved in `policies/fable-rulings.json`. Every other send, and every
  free-form reply (`intercom-ops-write.sh`), still needs a human Slack id: a script name is not
  an approver. The registry is data, so widening a class is a reviewed edit; an unreadable or
  malformed registry refuses rather than opens. The `approval_ref` (his 22:12Z words) is pinned
  and recorded with every send, and each claim is stamped with `approver_kind` +
  `approval_id` + the template identity hash (`campaign|kind|copy|variant`), so
  "who authorized this note, and which template did it render?" is answered by the ledger
  alone. `scripts/audit-approval-stamps.sh` (every 15 min, #clio_devops) pages when a send from
  2026-11-04 on lacks a stamp it can verify; it never repairs and never deletes evidence.
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
recording new replies, so a reply to the decline in any thread of the note
holds that credit's removal for a human. Nothing else
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
| Follow-ups | day 14 and day 25 (the second says it is the last), only for credits no review has ruled on. A closed request is the separate `decline` campaign, never a follow-up. A follow-up with nothing left to send (every credit documented, approved by a person or no longer approved) is closed as `skipped`; one whose user is waiting on a pending document stays due. Only follow-ups actually sent count against `--max-users` | **none**: one message per user, ever, and never to a user who already sent proof |
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
  `other_role`, `unreadable`, `not_a_document`; it stays INTERNAL (the `decline` copy states
  no reason at all), so neither the reason nor the file name ever reaches the user. After a reply with no document a rejection takes no reason. Once every credit on the note is
  reviewed and any was rejected, the note goes back to "no proof" and the sweep re-tags it
  only when a NEW attachment arrives (which puts every rejected credit back under review).
  A reviewed credit never gets a day-14 / day-25 reminder ("We haven't received a document
  yet" would be false).
- **After a rejection** each rejected credit gets ONE `decline` note, ever — its own campaign,
  not a follow-up, and `initial` kind only (no reminders, no second note). The batched
  `decline` campaign sends it (one message per user per UTC day, 7-day cooldown, once per
  request id ever). **The copy never says which check failed and never teaches the
  process** (captain 2026-10-29 13:2xZ, `decline-copy-ruling.md` item 1; wording captain
  2026-11-12 ~01:00Z: say it is denied for now, no reason, never fraud, they can resubmit):
  "We finished checking your credit request. For now the credit is denied: the verification
  didn't prove out." + "You can resubmit for the credit again later." + `Muso.AI`. Like every
  note from this sender, the rendered bytes also need a signed reviewer verdict before they
  leave (`outbound-copy-gate.md`). The five reasons
  (`doesnt_name_you`, `other_track`, `other_role`, `unreadable`, `not_a_document`) stay
  INTERNAL — on the `verify_proof_reviews` row and the executor's audit file — because a
  fraud denial and an ordinary shortfall are the same sentence to the customer. The gate
  refuses any payload that carries a reason, any copy matching `DECLINE_FORBIDDEN`, and any
  payload whose credits mix claim keys with request ids.
  The decline names **no date**: a declined credit is removal-due from the original note's
  own `removal_day`, and only once the decline was actually sent (`HELD_NOT_TOLD` before
  that). A credit a review did not rule `rejected` is never declined.
  **Only ONE of core and hydra may speak** (item 3): core already emails `credits_rejected`
  on a rejection, and after the muso-messaging template change that email carries this same
  approved text — so hydra's campaign ships SILENT (`DECLINE_CORE_ROUTE_OFF=0`: every real
  send refuses, `--dry-run` still renders). It activates only for a user whose core route is
  **measured off** (`scripts/credit_review/decline_close.py` reports `core_email` /
  `hydra_decline` / `hold` per user; an unknown route word or an unreadable ledger HOLDS).
  **The gate asks it per user before it claims anything** (`decline_close.py --user-id <id>`: exit 0 only for
  `hydra_decline`), so the activation switch alone can never send to someone core already told, and never sends
  while the route is unreadable. `core_email` and `hold` both print `HELD decline_<decision>` and claim nothing.
  Two things make that read evidence rather than an impression. **The window is the CLOSE of these credits**
  (`verify_ledger.py close-since`: the earliest `rejected` review on them, minus a day; a credit no review names
  falls back to the earliest note that asked for it, which only widens the window), so a core note about an earlier
  close neither suppresses this one nor falls outside it — and no close time at all is a HOLD, not a send.
  **Every psql call is strict** (`-v ON_ERROR_STOP=1`, and any stderr or unexpected row shape reads as "could not
  read the ledger"): psql otherwise prints an error and exits 0 with empty stdout, which would look exactly like
  "core told nobody".
  **A note is never attributed to a request** (QA #1718, 2026-11-06): `send.messages` carries no request id, so a
  `credits_rejected` row for this user since the close may belong to a DIFFERENT request that closed at the same
  time or later. Reading it as "core told them about this one" would leave this request silently untold, so a
  positive note is a `hold` a person sees, never a `core_email` claim the ledger cannot support. Only the
  configured route can say `core_email` for everyone, because a routed template emails on every rejected
  transition — a statement about all requests, not about one row. No note since the close is still sound evidence
  that core did not tell them: core's email is emitted on the `rejected` transition, so it can never predate it.
  **The template is the one the decline is about** (QA #1718, 2026-11-06): a credit is declined by core's
  `credits_rejected` email and a profile claim by `profile_claim_rejected`, and the two have their own routes. The
  gate passes `--template profile_claim_rejected` for a `claim-<id>` request and the default `credits_rejected`
  otherwise, and BOTH the route read and the ledger read use it — judging a claim by the credit route would read
  "core emails credits" as "core told this claimant", and the claimant would never get the decline the copy promises.
  **The close boundary is immutable** (same review): `verify_proof_reviews.reviewed_at` is overwritten by a later
  re-rejection and `mark_tagged` deletes the old verdict, so a review timestamp alone moves FORWARD — and a boundary
  that moves forward excludes core's earlier decline email, a zero count reads as "core never told them", and hydra
  sends a second decline for the same request. The floor is the **day of the earliest note that asked for these
  credits**: a request cannot be closed before it was asked, and a note's `day` is written once and never edited, so
  no later review can move it. `close_since` takes the EARLIER of the note day and the earliest surviving rejection,
  so the window can only ever widen toward silence. The cost is a wider window for a credit asked long before it
  closed (a core note about another of that user's requests inside the gap holds this one) — the safe direction,
  since a hold is printed and a person decides while a duplicate decline is invisible.
  **The removal path asks core too** (same review): a rejected credit is only removed once its owner has been told,
  and with core's route ON the telling is core's email — hydra writes no `decline` row at all. A removal decision
  that reads only hydra's ledger therefore holds every rejected credit as never-told forever, which is what the
  retired after-rejection note used to prevent. `decline_close.core_told` answers for core (routed = every rejected
  credit is told, because core emails on the `rejected` transition; off = core told nobody, hydra's own sent row
  decides; unreadable = `None`, which holds), and `credit-review.py verify-notify --removal-due` passes it into
  `verify_ledger.removal_due` / `held_for_human`. **A user-level count is never per-request evidence**: no store we
  can read carries a request id — `send.messages` has none, and ClickHouse `messaging.email_events` has none either
  (`event_time, event_type, source, template_key, subject, campaign_name, provider, reason, email, user_id,
  event_id`) — so a note cannot be attributed to a credit. Counting rows cannot close that gap: one credit rejected
  twice produces two notes, so a count of N does not mean N distinct requests were told, and a count of at least N
  does not mean every request was. `core_told` therefore never answers `True` for a specific request while core is
  the teller; a note that exists but cannot be attributed holds the credit as `HELD_NOT_ATTRIBUTABLE` (distinct from
  `HELD_NOT_TOLD`, which means no note was found at all), and a person decides. **The consequence, stated plainly:**
  while core's `credits_rejected` route is on, a rejected credit is never auto-removed — it appears in
  `held_for_human` for review. That is the fail-closed direction (a held credit is visible to a person; a credit
  removed from someone nobody told is not), and it is the price of core's email carrying no request id. The day it
  does, only `core_told` changes: the ledger already releases on a `True`.
  Two declines for one request is the one outcome both paths must never produce.
- **A reply to the decline** (text or attachment; the latest user reply's own time is
  recorded per message, `last_reply_at`) holds the credits that note named for a human until
  a review rules on them again. A new document sent in reply is tagged (the decline joins the
  note's family), which clears the earlier rejection and puts the credit back under review —
  the fresh review the copy promises — and holds it for a human. A decline may name credits of
  SEVERAL notes (a user rejected on two of them): the verdict for each credit is filed under
  **that credit's own note** (`verify_proof_reviews.family = the note that asked for the
  credit`), and the re-tag clears every rejected verdict the decline covered, not only the
  first note's — otherwise the promised fresh review could not complete for the second note.
- **Held for a human** (`FILE.held`, counted in the run summary, never in FILE), each with its
  reason: a credit past its date whose document still awaits review (`document awaiting
  review`, including a credit the reviewer never ruled on), a credit whose user replied to the
  note in any way and no review has ruled on (`extension_requested_at`; the run summary also
  reports each newly recorded reply), and a rejected credit whose decline has not gone out,
  and a rejected credit whose user replied after its decline. A human picks them up with
  `--proof-review`.
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

- **uvn-status** (Fable ops-takeover section 2 class 2; copy approved by firstmate 2026-10-19 21:07Z): one status + reminder per user whose credit requests wait on them (`user_verification_needed`), ever. It is an ask. It also asks the decider's per-role splits (`approve_partial`) that still owe roles while core shows them `unverified` - the ONE decider-driven exception, admitted by `uvn_status.partial_pending_ids` and not a widening of the campaign's statuses; see [`credit-trust-decide.md`](./credit-trust-decide.md) § Per-role decisions.
  - **Driver:** `credit-review.py uvn-status --list <newest dated uvn-reminder-list.json from credit-trust-llm-t01> --segment paid|free --mode apply --max-users N`. Canary: `--max-users 3`. At most 400 per UTC day. Kill switch: `/etc/hydra/credit-ops-notes.disabled` (see Operate). A dry run's `--preview DIR` writes one file per user, named by the Muso user id (`<user id>.txt`).
  - **Budget:** users the ledger already answers for (listed requests noted or closed, already sent, proof received, messaged in 7 days, asked in the last 90 days by any ask campaign) are dropped before the per-run budget is spent, so repeated runs keep reaching new users. A real run closes the ones done for good, no longer waiting, or without an account email. The 7-day and the 90-day one-ask lock are deferrals: nothing is closed and the user is offered again once they lapse (the run reports them apart, as "deferred (messaged in the last 7 days: ...)" and "deferred (asked in the last 90 days)"). The ledger checks the 7-day cooldown first, so a user under both can be counted in the 7-day figure and stays deferred after those 7 days end; the 7-day label says so. A reply-due answer skips that cooldown (`skip_7d`), and so does an ask that corrects our own sent status line (class C, below), so such a user is reported under the ask lock instead. Every other deferral (a read hold, the run's budget, another answer from the ledger or the gate at send) is reported as "deferred for another reason", which names the gate's own waits: a core notice in the last 7 days, a refusal re-check, the daily cap and the ask lock. Users the gate defers for a recent message in Intercom do not use the budget either: the run keeps going past them, at most 5 gate calls per budgeted user. For the status notes (below), a gate refusal does not use the budget either; it counts toward the same 5-calls-per-user cap and follows the 7-day re-check / 3-strikes rule. The hold is found by the account email OR the Muso user id, so an email change neither frees the user early nor resets the strike count. A pending request with a blank title, artist or role, a field over the gate's caps (role over 120 characters, title or artist over 200) or a malformed profile or track id is never shown: it is left out of the note and the rest of the note is sent (firstmate 166). It stays pending in core and is reviewed, and is counted in `rows_held` ("request(s) left out of a note") when the note is sent or, on a dry run, validated; a deferral, refusal or skip counts nothing. The note is one per user, ever, so this campaign does not ask about it again: a later run that still lists the user records it as skipped in the ledger. Only a user with nothing showable is held (`incomplete`, not closed) and re-checked on the next run, once a field is fixed. A request still waiting on them that the list does not carry (opened after the list was built) holds the user the same way (`unlisted`, not closed) until a rebuilt list names it; a request the note would never ask about (approval path, already on the profile) does not.
  - **Re-checked before each send:** the list is at most 30 h old (re-run `build.py` the morning of a send day); the strict proof-on-file rule (any entry = no ask; UNKNOWN = nothing sent); the request is still UVN on the replica (Trino, never admin paging), except a per-role split named by the decider ledger, and the `incomplete` / `unlisted` holds are applied again on that same read; in the gate, documents attached or tagged in Intercom = skip, any admin or Caroline message in 7 days = defer (a conversation we opened counts only when it was opened in those 7 days), the ledger (one per user ever, 7 days, one message per user per day, and the one-ask-per-user-per-90-days lock across verify-live, retro-past and uvn-status: a deferral, nothing closed, the gate answers `DEFERRED recently-asked`).
  - **No second ask** (Fable via firstmate 094, narrowed by firstmate 102): the replica re-check leaves out a request whose `verificationData.duplicate_of` is set (already on the profile, firstmate 086) or that the approval path can actually admit (it sends one v1 note): ALL of validator-approved (`is_approved`), `total_risk_percent` < 30, track popularity 1..59, for a one-person role no trusted source crediting it to someone else (`rule_risk_percent.review_role_credited_to_other_at_trusted_source` 0 or absent), and no server proof reason (`policy.server_proof_reasons`, the mirror of core's agent-approval guard) other than a band-hint-only stamp. A missing or unreadable field never leaves a request out. The run reports `already_on_profile` / `approval_path` (no ledger row: they leave the list once approved) and `low_risk_asked` (validator-approved, risk < 30, but the server needs proof: asked as normal); the note names only the remaining requests, and a user with nothing left to ask about is not messaged.
  - **Delivery:** in the user's most recently updated OPEN conversation of the last 14 days when there is one, otherwise email (see in-thread delivery below). A conversation the gate picked that fails a check (another contact, a human assignee, a do-not-message tag, unreadable) is dropped and the note goes by email: nothing is refused and the ask stays open (firstmate 066). A failed or unverified lookup of the open conversations sends nothing and claims nothing; the next run tries again (firstmate 071).
  - **Copy:** up to 3 titles, then "and N more". One request with several roles (role text `Mixing, Mastering`) asks for "something that shows your Mixing and Mastering credits" (roles joined with ", " and a final " and "); one role stays "your Mixing credit" (firstmate 118 c). The list sentence is Caroline's Step 2 ask marker, so her ask-once guard counts this note as an ask.
  - **Per-role partial lane** (captain 2026-11-06 ~17:05Z): `scripts/paid-status/daily.sh` runs `scripts/paid-status/partial_asks.py` to build `list-P.json` and passes it through this same runner, so every cap, the kill switch, the fraud lens and the segment's own holds apply unchanged. It has its OWN switch, `PARTIAL_ASKS` (default 0; the installed `/etc/cron.d/hydra-paid-status` lines leave it unset until the per-role core write ships, because an ask must never reach a customer while the proven roles are still unapproved), because the general ask lane's `ASKS` stays unset (firstmate 024). The population and the ask-hold markers are in [`credit-trust-decide.md`](./credit-trust-decide.md) § Per-role decisions.
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
  - **Replica re-check** (firstmate 076): the listed requests must still be pending (`user_verification_needed`, `unverified` or `processing`, not deleted); uvn-status keeps `user_verification_needed` only, plus the decider's per-role splits (above). A status-note user with none left is counted as `not_pending` and never closed in the ledger.
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

**Status:** the campaign is **send-locked again** (`CLAIM_PROOF_ASK_COPY_APPROVED=0`, captain 2026-10-27 01:1xZ): "The proof ask stays off. It offers paperwork and nothing can accept a valid ID yet." (Fable had ruled it send-as-is on 2026-10-26, firstmate 022.) The copy is Fable-approved (D38, `copy-ruling-claim-proof-ask-1022.md`), with paragraph 3 amended exactly as `claims-documentation-readiness-1023.md` ruling 1: "If adding the code isn't possible for you, reply to this message with paperwork that shows your name on one of {profile_name}'s releases: a split sheet, a producer or mixing agreement, an invoice, a royalty or distributor statement, or a PRO registration. Attach it here; we never ask for ID to claim a profile." A paperwork reply goes to document checks and then to the claim document ladder, which records a decision with no person in it ([claim-doc-ladder.md](./claim-doc-ladder.md)); it never auto-approves. `--dry-run` renders exactly what would be sent.

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

## Approved-for-another-user line (`--campaign credit-approved-elsewhere`; UNAPPROVED, SEND-LOCKED)

- **Who:** a credit request the conflict rule decided `credit_approved_for_another_user`: the same track and role is already verified for another person. The decision is not this gate's, and not `need_asks.py`'s either: both read the stamp the rule writes on the core row (`metadata.precedent_blocked`, PR #1971) and neither re-derives a conflict. A build without `--blocked-stamps` never reads it, and no stamp means no row at all.
- **Copy:** it says the credit is verified for another person and what to send if the requester shares it. It names nobody, gives no date, denies nothing, and carries no em dash. **The roles are the ones the two requests SHARE** (the stamp's `roles`), never the request's own role list, so the sentence is true per credit: a credit that names no role is refused, never rendered with a blank or with the requested roles. The plural branch names up to 3 titles (`MAX_LISTED`), each with only its own shared roles, then "and N more", and never says or implies that every requested credit is verified elsewhere.
- **Locks:** `APPROVED_ELSEWHERE_COPY_APPROVED=0`, so every real send refuses at the go-live guards and `--dry-run` renders exactly what would be sent. The campaign is `enforce` in `policies/outbound-copy-enforce.json` from its first byte, so no unreviewed body sends whatever the lock says ([outbound-copy-gate.md](./outbound-copy-gate.md)).
- **Ledger:** a notice (`NOTICE_CAMPAIGNS`): only its own rows block it, one message per request ever, it is not an ask and closes no ask. No follow-up kind. Its own `attempted`/`sent` row is also the ONE record of who has been told, read by the build and again by the proof-need-ask send (so a list built without `--blocked-stamps` cannot ask it either); the stamp's `line_sent` flag is never that record. The cases are the module docstring's.
- **Sender:** `need_asks.py send-elsewhere --list FILE` renders and validates only, and a real run halts before any ledger or replica read: the copy lock is 0 **and** the campaign has no daily cap and no row in the shared credit budget (`policies/credit-verify-outbound.json`), which opening the lock does not create.
- **Audience:** `need_asks.py build --blocked-stamps` puts a stamped request whose shared roles are readable under `elsewhere`, and every stamped row its campaign would refuse (roles unread, a stamp that is not an object, no account, a stamp naming another reason, and a stamp whose `line_sent` says true while the ledger holds no sent row: `told_flag_no_ledger_row`, kept off the line because a second message is never sent on a guess) under `backlog` as `backlog:no_send_route` with its `why`. A stamped request is never also a `users` ask or a `wait:` row, and a request the ledger says was told the line is in neither list. Each counter is named for what was measured, the run prints the stamp read on stderr zeros included, and the counters are the module's own (`scripts/credit_review/need_asks.py`).

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

## A note step that times out is UNMEASURED, never a refusal (firstmate 748, the 15:05Z auto-kill)

The gate call is the one place where a run's outcome can be genuinely unknown: the POST may have landed. A retry is
safe because the gate writes its CLAIM before it posts, and that claim is keyed on the user AND the day - so a re-run
of the same user finds the claim and answers without a second note. (The 7-day per-user window is the backstop across
midnight, not the mechanism.)

- **Bounded retry with backoff, on the note POST only** (`NOTE_ATTEMPTS=3`, `NOTE_TIMEOUT_S=55`, `NOTE_BACKOFF_S=(10,
  25)`): a timeout is retried, then raised as `NoteTimeout`.
- **The retry budget is charged to the tick, and the tick sizes an apply by the EXPECTED cost, not the worst case.**
  The worst case one user can cost is `3 x 55 + 35 = 200 s` (`WORST_USER_S`). `scripts/credit-verify-outbound.sh`
  sizes the apply at `APPLY_S_PER_USER=40` - a note step measured at ~40 s, the EXPECTED cost (`APPLY_USER_WORST_S=200`
  guards the worst case separately) - because sizing at the worst case would cut the page by 3x: at the old 15 s a slow
  run ate the hard deadline and the family then deferred every tick (the 11-02 "tick budget reached; this family
  waits" livelock), and sizing at 200 s would have deferred most of a page that fits. What pays for the difference is
  the guard below.
- **The budget is ONE RUN clock, not one clock per send.** `[key=note-step-budget]` (QA #1756): the per-user caller
  (`uvn_status.run()` calls `send_all([p])` once per user) used to restart the clock on every user, so N slow notes
  could together overrun the share the tick gave the family and hit its hard deadline mid-apply - a partial send, then
  the auto-kill. The clock is the apply SESSION's (one lock, one start, `APPLY_BUDGET_S` measured from it), so the
  share is spent once however many `send_all` calls the run makes.
- **A user whose whole retry budget does not fit what is left is DEFERRED, never started** (`spent + WORST_USER_S >
  APPLY_BUDGET_S`): no row, no claim, still owed, reported as `apply_budget` - so one slow user can overrun the share
  by at most one retry budget, and only the last one started.

## A page too big to fit is CUT to what fits, never dropped (`[key=tick-budget-page-fit]`, 2026-11-11)

A paged family's worst-case estimate before it starts is `2 x max(cap, its page) x CHECK_S_PER_USER +
RESERVE_PAD_S` (the check and the bodies each walk the page). The page is a SIZE knob, so it decided
whether the family ran AT ALL: on 2026-11-11 a live `CHECK_ENTRIES=600` on node-8 (one knob for every family then)
made that estimate 5,100 s, the tick
reached uvn-status ~3,963 s in (the builders and reply-due run first), and `3,963 + 5,100 > 6,900` skipped **every
family on every tick** for hours - the tick never reached a send, and raising the page size made it strictly worse.

A page that does not fit is now cut to what fits and the family runs. The walk still starts at the same cursor and the
cursor still advances from the check's own page record, so a smaller page is a SLOWER page, never a skipped one.
`PAGE_FLOOR` (`CVO_PAGE_FLOOR`, default 20) is the smallest page worth the setup cost; below it the family still waits
for the next tick. This is live at the shipped pages, not only a guard: the sending family's estimate is 5,100 s at
its 600-entry page, so whenever it starts more than 1,800 s into the tick it walks `(6,900 - elapsed - 300) / 8`
entries instead of 600 (329 at the 3,963 s above). A 200-entry family's estimate is 1,900 s (2,300 s at the full 250
cap), so it is cut only when it starts past 5,000 s (4,600 s).

## Three pages: 200 entries for every paged family, 600 for the one that sends, 100 for the reminder and the new-rows follow-up (`[key=walk-size]`, `[key=send-page-per-family]`, 2026-11-13)

A paged family (wait-apology, reply-due, uvn-status, r1, proof-need-ask, uvn-reminder-14) walks one page per tick,
counted in list entries that still need a live-gate check. `scripts/credit-verify-outbound.sh` has three page sizes:

| knob | default | who walks it |
|---|---|---|
| `CHECK_ENTRIES` | 200 | every paged family |
| `CHECK_ENTRIES_SEND` | 600 | **uvn-status free only** - the family that sends the notes |
| `R14_ENTRIES` | 100 | **uvn-reminder-14 paid and free** - its list is already cut to the people the ledger says are due |

All three are code constants in production (`cfg()`), and `page_entries()` picks one from the family's own name, segment
and subcommand - the same arguments that key its cursor and its policy `tick_cap` - never from where the call sits in
`credit_families()`. `uvn-status paid` stays on 200, and so does `reply-due free`, which runs the same subcommand on
the same segment.

- **Why the sending family has a larger page.** The page, not a cap, was what limited sends: the 2026-11-13
  01:10:23Z run walked 200, found 15 sendable (about 7.5%), sent 15 notes and left 2,319 entries unwalked, while
  `CVO_CAP` is 250 and was never reached.
- **Why only that family.** #1928 raised the one global knob 200 -> 600. Four paged families run ahead of uvn-status
  free (reply-due paid and free, uvn-status paid, r1 paid). Each of them then walked up to 600 entries a pass
  (~2,400 s at 4 s an entry) where it had walked 200 (~800 s), and every second they spent started the sending
  family later, where the section above cuts its page. The raise slowed four families and shrank the page of the one
  it was for. This change corrects that: the larger page is the sending family's alone. The reminder's own 100-entry
  page is the third size for the opposite reason - the ledger has already cut its list to the people who are due, so
  a short page fills its 50-a-tick cap and it does not need one.
- **The deadline arithmetic, one family at a time.** The tick's own guard computes `SEND_WORST_S = 2 x
  max(CHECK_ENTRIES_SEND, CAP) x CHECK_S_PER_USER + RESERVE_PAD_S` = `2 x 600 x 4 + 300` = 5,100 s against
  `TICK_HARD_S` 6,900 s: 1,800 s to spare. The largest send page that fits a tick alone is 825. A 200-entry family's
  worst case is `2 x 200 x 4 + 300` = 1,900 s, or 2,300 s where its cap is the full 250 (the walk is
  `max(page, cap)`).
- **The deadline arithmetic, the mixed case. It does not fit.** The families that always run ahead
  (reply-due paid and free, uvn-status paid, r1 paid at their 200-entry page; uvn-reminder-14 paid and free, which runs
  between the paid families and the free ask at 100, and starts no family at all when nobody is due) cost
  `4 x (2 x 200 x 4) + 2 x (2 x 100 x 4)` = 8,000 s, and the sending family's own check and bodies cost
  `2 x 600 x 4` = 4,800 s: 12,800 s against 6,900 s. wait-apology paid and free run ahead too whenever a paid-status
  plan exists for the day, adding `2 x (2 x 200 x 4)` = 3,200 s, so the
  mixed case is up to eight families, 11,200 s ahead and 16,000 s mixed - worse, never better. It did not fit with
  every family on 200 either (`5 x 1,600` = 8,000 s). With the always-present families ahead,
  `6,900 - 8,000 - 300` is already negative, so the cut floors at `PAGE_FLOOR` and the family waits; while the four
  200-entry families were the only ones ahead the send page that still fit was `(6,900 - 6,400 - 300) / 8` = 25
  entries. The worst case is
  an estimate of 4 s for every entry, twice, in every family; the tick does not rely on it holding, it measures
  `elapsed` when each family starts and cuts the page then. `TICK_HARD_S` is not raised for this.
- **600 is the most the sending family walks, not what it is promised.** It gets the whole page only when it starts
  within 1,800 s of the tick's start. What this change removes is the extra delay the families ahead of it added on
  600-entry pages; it does not make them faster than they were at 200. How many notes a tick sends is measured from
  `run.log` after deploy, not derived from a ratio.
- **Nothing else moved.** `CVO_CAP`, the tick budget and deadline, the per-user estimates and every stop rule are as
  they were. Accepts are still bounded by the cap and by the policy `tick_cap` (uvn-status: 50 a tick per segment,
  paid and free).
- **What it costs, on the sending family.** The check and the bodies each walk the page, so its read-only gate calls
  go from at most 400 to at most 1,200 a tick. And the runner's unmeasured stop is a share of the page
  (`max(5, 10%)`): on a full 600-entry page it stops at **60** unmeasured users where a 200-entry page stops at 20.
  A slow gate is therefore noticed three times later on the sending family - up to 60 users timed out before the run
  fails loudly instead of 20. Every other 200-entry paged family keeps the 20-user bar; the reminder's 100-entry page
  stops at 10 (`max(5, 10%)` of what it walks).
- **Tests.** `scripts/tests/credit-verify-outbound.bats`: the `[key=send-page-per-family]` cases pin 200 / 600, that
  only uvn-status free is handed the larger page, and the mixed-case numbers above; the `[key=walk-size]` cases pin
  the fit and what happens one entry past 825, and the reminder's own `R14_ENTRIES=100` page (`uvn-reminder-14` row).
  A global raise, a send page that does not fit, or a page moved onto another family fails in CI.
- **Revert.** Set `CHECK_ENTRIES_SEND` to 200 in the script and in the bats cases that name 600 as the shipped send
  page (the `--print-config` expectation, the `[key=walk-size]` shipped-page case and the two
  `[key=send-page-per-family]` cases).

## The apply loop is a bounded pool of 6, keyed per user (`[key=apply-pool]`, captain 2026-11-11)

A real send used to be strictly serial, so a run walked ~75 users at `APPLY_S_PER_USER=40` and the untold backlog took
~15 h. `verify_notify.APPLY_WORKERS = 6` note steps now run at once. What makes that safe is not the pool, it is the
key:

- **The idempotency key is `campaign|user|UTC day`, checked BEFORE a worker starts.** Two checks, both before the gate
  is ever called: an in-run `seen` set (a duplicate payload for the same user is a `duplicate_idempotency_key`
  deferral, so two workers can never both send for one person) and the durable `verify_ledger.capped` predicate (a
  user the ledger already noted today is an `already_notified_today` deferral, so **a re-run sends nothing**). `capped`
  is the same predicate `claim()` refuses on inside its `BEGIN IMMEDIATE` transaction, so the pre-check can only defer
  a user the gate would itself have deferred - it never invents a refusal. The gate's atomic claim stays the
  authority; the key is the cheap proof in front of it.
- **Only the gate subprocess leaves the caller's thread.** Every counter, every guard, the outcome file and the stop
  bars keep exactly one writer, and results are consumed in LIST order, so the accounting is identical to a serial
  pass. A worker's exception is that user's row (`error`), never the batch's.
- **Pacing is a RATE, not a per-user sleep.** The serial loop slept `pace_seconds` between users; the pool sleeps
  `pace_seconds / workers` between submits, so the aggregate send rate is exactly what it was.
- **The budget guard is unchanged** (`spent + WORST_USER_S > APPLY_BUDGET_S`): the workers run concurrently, so the
  wall-clock worst case is still ONE retry budget, not `APPLY_WORKERS` of them.
- **The tick sizes the apply at `remaining x APPLY_WORKERS / APPLY_S_PER_USER`** (`scripts/credit-verify-outbound.sh`),
  i.e. six times the users for the same remainder. The pool is bounded at 6 on purpose: raise it only after measuring
  what the admin API sustains.

**The pool does NOT reach the uvn-status family, and that is the family carrying the backlog.** `uvn_status.run()`
calls `send_all([p])` once per user in apply mode (a fresh replica re-plan, `asks_proof_on_file`, `stage2_released`,
`plan`, `documents_block`, `read_hold_until` and `apology_states` immediately before each send), so `_send_loop` sees a
one-payload batch and runs it with `workers = 1`. The pool is real for the families that hand `send_all` a batch
(`claim_proof_ask`, `need_asks`). Batching uvn-status's apply walk would widen the window between those reads and the
send, so it is a separate change that needs a ruling, not a side effect of this one.

- **A timeout is not erased by the retry's answer.** The gate claims the user BEFORE it posts, so when the first POST
  times out and a retry answers `SKIPPED already-notified`, the run cannot tell "the timed-out POST landed" from "it
  died after claiming". That user is `timeout` (UNMEASURED), never `skipped`: a skip asserts we know nothing went out.
- **Read-only gate calls are never retried** (`READ_TIMEOUT_S=20`, one attempt): `--check-recipient` / `--validate` /
  `--dry-run` run on `CHECK_WORKERS=4` threads, so a retry there multiplies across threads, and none of them posts.
  Everything else through the runner keeps main's single `OTHER_TIMEOUT_S=180` attempt. A read-only call that exhausts
  its 20 s is not a failure of that user (and never raises out of the parallel pre-gate): the runner returns the
  synthetic UNMEASURED result, and `_send_loop` records that user `timeout` (`gate_timeout`) on the main thread while
  the batch continues.
- **One user's unknown outcome never costs the batch; `max(5, 10% of the batch)` of them stop the run.** `NoteTimeout`
  (and any exception raised inside the gate) is recorded on that user's own outcome row as `timeout` / `error`, counted
  once on the main thread, and the loop continues. At `unmeasured_users >= max(UNMEASURED_STOP_MIN=5, 10% of the
  batch evaluated so far)` (`verify_notify.unmeasured_stop_after`) the run stops LOUDLY: `stopped_on_unmeasured`,
  `unmeasured_stop_at` and the per-user `unmeasured_reasons` are written to the outcome file and printed in the
  summary/tick.log, the users behind the stop keep no row (still owed, walked again next tick), and no further POST is
  made - dry-run and apply alike break the walk on the stop. The bar is separate from, and higher than, the systemic
  failure bar (`max(3, 2%)`): a timed-out read says nothing about the account, so it is counted as UNMEASURED and only
  a run of them is a statement about the gate. The outcomes artefact is therefore ALWAYS written, and it names success
  / timeout / error for every user the run touched; users it never reached keep no row at all.
- **A `timeout` / `error` row is never a refusal.** The tick's refusal ratio counts only `result` values that start
  with `refused`; an UNMEASURED note adds no refusal, so a run whose note steps timed out does not read as a spike.
- **The missing-artefact policy is not this one.** An apply that sends rows and leaves no artefact at all is
  `#1747`'s contract: it stops the family and KILLS, naming the artefact, so a human reads the rows back before the
  family runs again. This change only guarantees the artefact exists.
- Why: at 15:05Z a note step hit the 180 s timeout, the exception escaped the send loop, the runner died before
  writing its artefact, and the tick read the missing file as "a refusal spike" - it auto-killed every family while
  nothing had been refused and the rest of the batch was still owed.

## A signed apply reads the replica per batch, not per unsigned user (2026-11-12)

The tick's apply sends only to its check's accepted set, and a user outside it takes no slot. `uvn_status.run()` used
to size each batch read to the slots left, so when the check signed one fewer than `--max-users` a single slot stayed
open for the whole page and the walk re-read accounts, the fraud lens and the pending rows once per unsigned user.
Measured on node-8, 2026-11-12 08:00Z, at a tick cap of 10: the free apply sent 9 in 6 minutes and then walked 101
unsigned users for 32 more; the paid apply walked 70 for 12. The tick reached its 6,000 s budget having sent 18, and
`r1-free` and all four claim segments waited for the next tick.

A signed apply now reads `SIGNED_APPLY_BATCH` (200, the tick's page) list entries per batch. The slots still bound the
sends, and the cursor still stops where the check stopped (`APPLY_RAW_END`). One accounting change: when the cap fills,
the users after the last send used to get a `deferred / run_size` row and now get `filtered / not_in_signed_accepted`,
like every other unsigned user in the page. A signed user the cap did not reach is still `deferred / run_size`.

## The send order is decided when the list is built (2026-11-12)

The tick walks each user-level audience list in list order and the runner only filters it by segment, so the list IS
the send order. `scripts/credit_review/audience_order.py` is the one rule, used by `owing_proof`, `need_asks`,
`receipts`, `reply_due_scan` and `paid_band_ask`: **paying at-risk, then paying, then free; the longest wait first; the
user id last.** `claim_list` is a per-CLAIM list with its own total key (`audience`, `at_risk`, `filed_at`,
`claim_id`), so it is not on this rule.

- **Where it was implicit before.** Each builder had its own `(not paid, waited)` lambda (owing_proof popped a
  private `_tier`). Paid-first was explicit; the tie was not. Two users with the same wait kept the order the replica
  or a dict returned them in: on a synthetic tie, 6 shuffles of the source rows wrote 6 different lists. The 08:00Z
  list of 2026-11-12 had 0 ties in 3,345 users, which is why nothing showed it.
- **`paid` is the builder's flag, and a checker must use the same one.** owing_proof marks a user paying when the
  request's WORKSPACE has an active or trialing subscription (`PAID_WS`). A check keyed on the subscription's owner
  user id reads a seat on someone else's team plan as free and reports an inversion the list does not contain.
- Pinned builder by builder, each on a tied wait and shuffled source rows: `test_audience_order.py`
  (`owing_proof`, `paid_band_ask`; two mutation cases that must fail), `test_need_asks.py`, `test_receipts.py` and
  `test_reply_due_scan.py`.

<!-- Reviewed baseline: deploy overwrites - 2026-10-27 (claim-lane-resume-c2, firstmate 035): node-8 holds the #1377-era text of this file, copied outside a deploy at 00:36:52Z; main is the reviewed text (proof ask and gap ask locked, claim status on). -->

## Class C (the /c2 corrected ask) is armed by its own row (`[key=class-c-is-a-row]`, 2026-11-13)

A uvn-status ask to a user whose requests an earlier status line of ours named ("our team is reviewing", "we received
your documents") opens with the approved correction `fable-copy-1030-r5/c2`. That is class C. The timer passes
`--no-correction` and the gate answers `DEFERRED c2_signed_only` unless class C is armed.

- **What it cost.** Measured over the 39 uvn-status checks of 12 and 13 November (`data/rapid-verif-final-h3/`):
  1,685 of 2,732 gate calls (62%) were answered `c2_signed_only`, and on the 13 November 10:39Z owing list the first
  thing between 949 of 3,251 listed users and an ask was this rule. Nothing could switch it on: the date lived in a
  code table with no entry, and `read_arming` refused `uvn-status:c2` as an unknown family.
- **The row.** `armed_families["uvn-status:c2"] = {"live": true, "paid": true, "unsigned_from": "<instant>"}` in
  `policies/credit-verify-outbound.json`. It is a SUB-class of uvn-status, read per segment (`c2_args`): `paid: false`
  sends corrected asks to the free segment only. No row, `live: false`, no date, a date still ahead, legacy arming and
  a malformed policy all keep `--no-correction`. `live: false` stops BOTH segments whatever `paid` says: the paid
  segment needs `live` and `paid` together (a family row lets `paid` stand alone; this row does not).
  `CVO_UNSIGNED_ALL=1` does not arm it.
- **It never arms the family.** A uvn-status family that is dry stays dry; the row only decides whether an armed
  uvn-status apply may carry the correction. Every other rule a corrected ask passes is unchanged: documents on file,
  the approval path, the 90-day ask lock, core's own notices, `comm_state`, the caps, one message per user per day.
  The gate's 7-day rule exempts only the status line being corrected (QA #1565).
- **A corrected ask goes by email, as its own message** (the gate refuses `--conversation` with /c2).
- **Disarm.** Remove the row, or set `live` to false. The tick reads the policy at every start; no deploy.
- This is not the first send of the class: 390 corrected asks went on 2026-11-01 (ledger 6338-6994).

## The day-14 reminder (`--campaign uvn-reminder-14`, captain 2026-11-13 15:08Z)

One reminder of a SENT uvn-status ask, from day 14, to a user who has not replied, has not sent a document and has
had no other credit note from us since the ask. One per user per ask: the reminder row names the ask it follows, so
only a reminder of THAT ask closes it (uvn-status asks a user once, so today one-per-ask and one-per-user select the
same people). Why: the 90-day one-ask lock
(`verify_ledger.REASK_LOCK_DAYS`) held every asked user out of every later tick, so sends fell to what the day's new
users allowed. The lock is unchanged for every first ask. The reminder is not in `ASK_CAMPAIGNS`: it never restarts
or shortens the lock, and `asked_within()` never counts it.

- **Who.** Measured read-only on node-8 on 2026-11-13 (`data/verif-reask-14d-r1/report.md`): 1,359 users whose last
  ask was 14 or more days old, with a request still waiting in core, no document and no reply; 1,353 of them were
  last asked by uvn-status, and 1,110 of those had no follow-up from any sender.
- **The rule is one function**, `verify_ledger.reminder14_why`, read by the audience builder
  (`owing_proof.py`, class `uvn_reminder_14`, written to `owing-reminder-14.json`), by the gate's peek and inside
  `claim()`. The reasons it gives, by name, are in its docstring. Deferrals: `no_prior_ask` (the user's last ask is
  not a sent uvn-status ask), `not_due`, `messaged_7d`. Closed for good: `already_sent`, `proof_received` (a
  tagged document, or one that was: an attachment counted on the note or a document review on record, since a
  rejected review clears the tag), `replied`,
  `already_reminded` (a follow-up of any kind from any sender, matched by account email too: the 2026-11-09
  `reminder-1` emails carry no account id), `noted_since_ask` (any other credit note on or after the ask day). Each
  build logs how many users each reason left out.
- **It lists only the rows the ask named.** A row opened since is the `uvn-new-rows` class and never holds or enters
  the reminder.
- **At the send**, for `comm_state` it is the uvn ask (documents on file, an acknowledgement, a decision already
  told and the 7-day rule all hold it) with `--reminder`: ANY customer message after the earliest ask on record holds
  it, a text reply included. No ask on record or an unreadable thread sends nothing. The attachment scan always
  runs; a stage-2 `no_document` verdict does not skip it.
- **Copy.** `uvn_reminder14` in the gate: "on <day> we asked for something that shows your <role> credit on
  <title> by <artist>. We haven't received it yet, so your credit request is still waiting.", then the ask's own
  list and closing. The day is the ledger's ask day, never the payload's. No deadline and no consequence. The
  campaign is `ask` in `gate.py`'s `CAMPAIGN_STAGE` (it is an ask), and the reviewer host must be running a tree
  with that row: `gate.review()` skips as `skipped_bad_request` any pending body whose recorded stage differs from
  its own `stage_of(campaign)`, so a host still on the old tree reviews nothing and no reminder is approved or sent.
  Deploy order: merge, deploy node-8, then re-run `scripts/outbound_copy/install-reviewer-host.sh` on the reviewer
  host from a tree containing the change.
- **No send without a signed verdict on the exact bytes.** The campaign is `enforce` in
  `policies/outbound-copy-enforce.json`, and the gate also holds an observe-mode pass for this campaign, so removing
  that line does not send it unreviewed. Each user's body is its own review. A body waiting on its verdict pins the
  page for THIS campaign only (`uvn_status.copy_verdict_pending`, applied when `campaign == REMINDER`): the next run
  starts at that user, where every other family's cursor still steps past a waiting body. So the first tick after a
  deploy queues bodies and sends none, and a tick that walks only unreviewed users sends none.
- **Caps.** 50 per tick, ONE budget across paid and free, paid first (`R14_CAP`, the policy's `tick_cap` can only
  lower it); each segment walks up to 100 list entries a tick (`R14_ENTRIES`, the page sizes are owned by §"Three
  pages"); 1,200 per segment per UTC day under the shared credit cap; one message per user per UTC day as for
  every campaign. Raise `R14_CAP` by PR after three clean ticks.
- **Arming.** Its own row, `armed_families["uvn-reminder-14"]`. No row, `live: false` or no date: it checks and
  never applies. A policy with no `daily_cap` row or no group for it skips the family and does not stop the tick.
- **Disarm.** Remove the row or set `live` to false; the tick reads the policy at every start.
- **The policy file on node-8 was hand-edited** (lower caps, `armed_families`) and a deploy replaces it whenever a
  PR touches it. The PR that added this family carried every value live on 2026-11-13 unchanged (sha256
  `4321089f...`, read 18:22Z and again 22:26Z); the file's `_doc` itemises each one old -> new. Diff the live file
  against the repo before deploying any change to it.

## The new-rows follow-up (`--campaign uvn-new-rows`, firstmate 2026-11-14 22:48Z)

The follow-up ask to a user we already asked, about owed requests that no ask named (the owing builder's
`uvn_new_rows` class). Opener `fable-copy-1101-r5/n1` ("Since we last wrote about your credit requests, ..."), then
the `uvn-status` body over the new rows only. Evidence and the measured audience:
`data/ask-never-asked-r1/report.md`, `data/ask-never-asked-r1/uvn-new-rows-bodies.md`.

- **Why the lock is open.** `UVN_NEW_ROWS_COPY_APPROVED` waited on a human sign-off of the family's first dry run on
  the deployed head. That sign-off was replaced by the outbound copy gate's signed verdict: the six bodies of that dry
  run were all approved by the reviewer round of 2026-11-14 22:40Z. Setting the constant back to 0 locks it again.
- **Every body needs its own signed approve.** The campaign is `enforce` in `policies/outbound-copy-enforce.json`,
  and the sender holds an `observed` pass for it as it does for the reminder. Bodies differ per user, so the first
  tick that renders a body sends none of them: they wait for the reviewer round and go on a later tick.
- **Who may get it is the ledger's rule**, `verify_ledger.new_rows_user_done`: only a user with a SENT `uvn-status`
  ask. A user core's own notice told and we never asked is deferred (`no_prior_ask`), never closed. Measured
  2026-11-14 22:45Z over the 1,404 listed users: 1,072 are `no_prior_ask`, 70 closed on a document, 107 inside the
  7-day wait, 155 may be asked. The family therefore reaches at most 262 users, not the whole class.
- **The tick family** (`new_rows_family` in `scripts/credit-verify-outbound.sh`): its own built list
  (`owing-new-rows.json`), paid then free, after the reminder and before the free ask's walk, a 100-entry page,
  always `--no-correction` (the `/c2` opener with this one is not approved copy).
- **The cap is 5 users per tick across paid and free together** (`NR_CAP`, a constant; `tick_cap` in the policy can
  only lower it) and 120 per segment per day. It is low on purpose: the family had never sent, and the first runs
  must be read before it scales. Raising it is a PR that cites those runs.
- **Arming** is its own `armed_families` row. No row, `live: false` or a row with no date checks and never applies.
  A policy with no `daily_cap` row or no group for the campaign skips the family and does not end the tick.
- **A build that writes no new-rows list is unmeasured, never "0 listed".** Every build of the tick asks for the
  class and the file is removed before each build, so a file on disk is the one that build wrote. No file, or a file
  that is not a JSON object with a `users` list, fails the family: the tick exits 1 and the other families still
  run. Only an empty list is "nobody is listed". A skip there would leave the tick green with nobody asked.

## The proof refusal (`--campaign proof-refusal`, captain 2026-11-15)

The note that tells a person why the document they sent did not verify a credit, and what would. Measured
audience and the held classes: `data/proof-refusal-send-r1/report.md`.

- **The copy is one sentence per track and one closing**, with no greeting and no sign-off:
  `{title} was not verified. Reason: {reason}. What would change this: {evidence}.`, then once, last,
  `Reply to this conversation with it and the check runs again automatically. Without it, the result stands.`
  A one-track note is one of the three bodies approved on 2026-11-15T13:41Z (corr=208a8463f735ff45), byte for
  byte. A note about several tracks repeats the sentence per track with that track's own reason.
- **Three pairs have a body**: `doesnt_name_you` or `other_track` with `counterparty_signed_or_registered`, and
  `unreadable` with `readable_document`. `{evidence}` is `proof_reviewer.ASK_LINES` for the need code;
  `scripts/tests/test_proof_refusal.py` holds the gate's words equal to it. Any other pair in a credits file
  refuses the whole note (`refusal_uncoded`): a track is never dropped silently and never given another track's
  reason.
- **A row is listed only where the reader recorded the need the body names**
  (`proof_review_decisions.ask_need`, `proof_refusal.build`). The rest are held and counted by class in the list:
  the reader's distributor-dashboard need (the `proof-need-ask` family owns it, with a code issued at send), a row
  the reader named no need for, a reason with no approved wording (`not_a_document`, `other_role`), a row with no
  account. On 2026-11-15 14:53Z that was 630 of 6,659 rejected rows, 81 people.
- **The send reads each listed request again** (`proof_refusal.payloads`): one no longer pending, one held for a
  cause no document clears (`policy.never_ask`, through `uvn_status`), one another ask class holds, one a
  `proof-need-ask` already named and one this campaign already wrote about are dropped with the reason.
- **The send reads the reviewer's decision again** (`proof_refusal.moved`). The list is built once per tick and
  the reviewer runs beside it, so a row stands only while its `verify_proof_reviews` row is still that rejection
  and its newest unreverted `proof_review_decisions` row is still a rejection for that reason, with that need, on
  that account. It is read for the whole page in every mode (a moved row is dropped as `decision_changed`), and
  on an apply once more per person immediately before that person's own gate call: any moved row holds the whole
  person (`deferred`, `decision_changed`, nothing claimed), and the next tick's build lists them from what the
  ledger says then. A ledger that cannot be re-read sends nothing; at the gate call it stops the run.
- **Ledger:** a notice (`NOTICE_CAMPAIGNS`): one message per request ever, it is not an ask and starts no expiry
  window. It keeps the 7-day rule (`DEFERRED messaged_7d`): a person who had any note from this gate in the last
  7 days waits and is offered again. Each sent row's `refs_json` names the `verify_proof_reviews` row every
  request answers (`review_family`, `review_reason`, `review_need`).
- **The lint** (`refusal_copy_guard`) reads the note with every title, artist and role replaced, so a song called
  "Review" passes and a banned word in our own sentence does not. A note over 1,500 words is refused, not cut.
- **Every body needs its own signed approve.** The campaign is `enforce` in `policies/outbound-copy-enforce.json`
  and the sender holds an `observed` pass for it. The reviewer reads it as a class 2 message of
  `policies/outbound-copy-rubric.md`. The first tick that renders a body sends none: it waits for the reviewer
  round and goes on a later tick.
- **The tick family** (`refusal_families` in `scripts/credit-verify-outbound.sh`): after the credit families and
  before the need ask; paid then free; a 100-entry page. `PR_CAP` is 100 per tick across paid and free together
  (a constant; `tick_cap` can only lower it) and the policy's `daily_cap` of 395 counts the campaign's own ledger
  rows across both segments.
- **No run without a clean read-back.** Before the list is built the tick runs `proof_refusal.py readback` over
  every note the campaign has sent: sent = claimed, 0 hard bounces, 0 spam complaints. Exit 3 (one of them does
  not hold) or 2 (the ledger or a contact could not be read) sends no refusal that tick, fails the family (the
  tick exits 1, the other groups still run) and pages once per distinct finding. It needs no kill file to stop
  and clears itself when the read is clean again; `/etc/hydra/proof-refusal.disabled` stops the campaign in the
  gate.

## What bounds a tick's sends: order, the claim slice, the not-reached page, class C, the gate's reads (`[key=claims-never-starved]`, `[key=class-c-precheck]`, `[key=gate-reads-beside]`, 2026-11-12)

Measured on node-8 on 2026-11-12: 44 sends by 16:35Z, every one of them `uvn-status`. Five things bound a tick, and
the configured caps were not among the ones that bound:

- **Group order.** `credit-verify-outbound.sh` runs the claim families FIRST on every day, then the credit families,
  then the need families. On weekdays the credit families used to run first; at 08:00Z they spent the whole
  `TICK_BUDGET_S` on 18 sends and all four claim segments logged `tick budget 6000s reached`. The claim group is the
  cheap one (11 min for all four segments with a 19-send apply), so it goes first and is held to its own
  `CLAIM_GROUP_BUDGET_S` (1,500 s) slice: once that is used it starts no new claim family. This is order and time
  only: caps, arming rows, the one-message-per-stage ledger rule and the gate are unchanged.
- **The slice bounds the claim family in flight, not only the next one's start** (QA on #1919). A slice that is only
  checked before a family starts can be overrun by one slow check or apply, which is the same starvation in the other
  direction. While the slice is in force a claim family's read-only steps (check, bodies, the shadow judge) run under
  the slice's end and are stopped there: nothing was sent, the family is counted as not reached, and the tick goes on
  to the credit families. Its apply is never killed (a kill mid-apply is a partial send). It is sized to the slice and
  handed the seconds left in it as `--apply-budget-s`, so the send loop starts no user whose worst case would pass the
  slice's end, and it does not start at all with less than one user's worst case (`APPLY_USER_WORST_S`) left. What can
  still run past the slice is never a new send: a user whose send outruns its own worst case (the loop only starts
  one whose worst case, `WORST_USER_S`, fits), and that apply's own read-backs. At the default slice one claim apply carries at most
  225 users (1,500 s x 6 workers / 40 s a user), under the default `CLAIM_CAP` of 250; node-8's claim cap is 25.
  A family that is started and then cut by the slice keeps its not-reached count: it sent nothing, so two ticks of
  that page exactly like two ticks of never being started.
- **A family that is not reached is counted, and an armed one is paged.** Every wait for time (tick budget, claim
  slice, a worst case that does not fit) goes through `not_reached`, which keeps `$STATE/starved-<family>-<segment>`
  and pages on the `STARVED_PAGE_AT`-th (2) consecutive unreached tick, again every `STARVED_REPAGE_EVERY` (12). The
  marker is written only on a confirmed delivery; a reached family clears both files. "Armed" and "running" are
  different facts, and tick.log was the only place that said so.
- **Gate calls, not the cap, bound `uvn-status`.** A check run may make `MAX_CALLS_PER_USER x tick_cap` gate calls
  (85 at a cap of 17). On the paid segment 67 to 77 of those 85 went to users the gate answers
  `DEFERRED c2_signed_only` (an earlier status line of ours named the requests, and the timer passes
  `--no-correction`), so the segment accepted nobody on three consecutive ticks with ~950 people on its list.
  `uvn_status.class_c_signed_only` now sets those users aside before the gate from the same ledger read
  (`verify_ledger.nothing_needed_overlap`), with the same `c2_signed_only` reason, at no gate call. It is deliberately
  NARROWER than the gate: only a FULL overlap is set aside (the gate narrows the ask to pending requests before it
  looks, so a partial overlap can still send and is left to the gate), and never with `--reply-due` or
  `--conversation`. A ledger that cannot be read sets nobody aside.
- **A gate call has to fit the runner's one 20 s read attempt** (`READ_TIMEOUT_S`, sized at about twice a ~10 s
  check). Measured 2026-11-12 18:2xZ by replaying the 18:00Z paid `uvn-status` check read-only: a gate call for a user
  with an Intercom contact took 15 to 19.6 s, because its reads ran one after another and every replica round trip
  costs 1.9 s before the replica does any work (`trino-query.sh` = `kubectl get pods` + `kubectl exec` + the CLI's
  start): core's notice read (one trip), then `comm_state.check` (the request read, up to 17 Intercom reads, then the
  fraud lens's three trips; 12.7 s for user 98255). Five of every twenty calls timed out, the SAME users each tick,
  and the segment ended at the unmeasured bar on the 17:03Z and 18:00Z ticks having sent nobody. `comm_state.beside`
  now reads the lens beside the other reads (`[key=gate-reads-beside]`): 12.7 s to 7.0 s for that user, 8.2 s to 6.0 s
  for six others, the same verdict each time. The timeout and the bar are unchanged. A check that stops at the
  unmeasured bar on the same users twice is a slow gate, not slow accounts: time one call before touching either.
- **The other reasons the claim families sent nothing from 11-07 to 11-12 were not the order**: through 11-12 04:35Z
  every tick skipped them at `list_signed_on_stale` (fixed by the `claim-list-build.timer`, #1903), and the
  `shared_daily_cap.claim` row on node-8 is 25 a DAY across both claim campaigns. Read the tick's own line before
  blaming the budget.

A family whose check accepts nobody says so per rule in `<family>-<segment>-check.json` (`outcomes[].reason`); count
those before raising a cap. A cap is raised because the gate accepts the people, never to move a number.
