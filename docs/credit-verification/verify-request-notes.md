# Trust yet verify: the "please help us verify it" note

> **firstmate 090 (2026-10-19 23:27Z): every verify-live note is the no-threat `v1` copy.** The captain dropped auto-removal (Fable ruling 4 as amended), so no message may name a deadline or say a credit will be removed. The gate sends `v1` for every new credit's note, but only when every credit is a server-confirmed decider approval (`verify_ledger v1-eligible`). The note records no `due_day` and no `removal_day`, so nothing is ever removal-due. `LIVE_WINDOWED_COPY_APPROVED=0` send-locks the windowed note and all of its follow-ups (day-14/25 reminders, after-rejection). The windowed rows in this document describe that locked path, kept for `--dry-run` previews only. The bats test "no sendable message carries removal or deadline language" fails if any sendable message, in any campaign, names a deadline or a removal. Unconfirmed credits go to the day-30 Ops review list (`credit-review.py provisional-review`, #1275); they are never removed automatically.

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
- The response must be an `admin_message` of the requested type with a numeric id.

`tag-proof --message-id <id>` acts only on a note this gate sent. The conversation's
`source.id` must be that note. Only parts authored by the contact we wrote to count, and
the reply text is never extracted. ANY such reply (text or attachment) records the latest
reply's time on that message (`last_reply_at`; `REPLY RECORDED` for each newer reply) and
`extension_requested_at` on the note once: the user may be asking for
more time, so the note's credits are held from removal for a human, and the run summary
says so. A reply carrying attachments also gets the `credit-proof` tag. A tagged thread is
never re-tagged (`ALREADY TAGGED`), but while its windowed note still has a credit no
accepted review cleared (awaiting review, or rejected) the sweep keeps reading it and
recording new replies, so a reply after an after-rejection note in any thread of the note
holds that credit's removal for a human. Nothing else
happens: no reply, no decision, no credit change. The Ops
document step (T07) picks tagged conversations up later.

Caroline's guidance for replies to these notes lives in
`workspaces/support/reference/credits-and-profiles.md` ("Credits Added on Trust"): thank
them, "we'll check it, usually within a few days", never decide.

## Operate

- Dry run (validates every note, sends nothing): `python3 /opt/hydra/scripts/credit-review.py verify-notify`
- Kill switch: `touch /etc/hydra/credit-verify-notify.disabled`, or set `enabled: false` on
  `credit-trust-verify-notify-15m`.
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
3. **Intercom check at send time** (in the gate, **past credits only**). If any conversation
   of the recipient holds a document the USER attached (in a reply, or in a conversation
   they opened), or is tagged `credit-proof`, the note is skipped and its credits are
   closed. Email replies land in Intercom, so this covers both channels. A contact with
   more than 150 conversations counts as "sent". A failed read sends nothing and claims
   nothing. `--doc-check` runs this check read-only for `--campaign retro-past` and never
   claims or sends; it is refused for any other campaign or kind. A new credit's note is
   never skipped for a generic Intercom attachment or a long conversation history.
4. **No repeats.** A credit asked about in any campaign is never asked about again. A past
   ask goes at most once per user, ever (any earlier note counts), and messages are always
   batched per user.

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
| Follow-ups | day 14 and day 25 (the second says it is the last), only for credits no review has ruled on; one `after-rejection` note after a rejected document. A follow-up with nothing left to send (every credit documented, approved by a person or no longer approved) is closed as `skipped`; one whose user is waiting on a pending document stays due. Only follow-ups actually sent count against `--max-users` | **none**: one message per user, ever, and never to a user who already sent proof |
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
  `other_role`, `unreadable`, `not_a_document`; it is the only "why" the user ever sees (never
  the file name). After a reply with no document a rejection takes no reason. Once every credit on the note is
  reviewed and any was rejected, the note goes back to "no proof" and the sweep re-tags it
  only when a NEW attachment arrives (which puts every rejected credit back under review).
  A reviewed credit never gets a day-14 / day-25 reminder ("We haven't received a document
  yet" would be false).
- **After a rejection** each rejected credit gets ONE `after-rejection` note of its own
  (verify-live only, same gate and send lock). A later rejection on the same note sends
  another note for the newly rejected credits only (batched per user, one message per user
  per UTC day). The copy depends on what was received on the note: after a document,
  "thanks for sending your document. It didn't confirm your {role} credit on ... because
  {reason}. If you have something else, ... reply to this message with it by {reply_by}";
  after a reply with no document (no `--reason`), "thanks for your reply. We still need a
  document that shows your {role} credit on ... If you have one, ... reply to this message
  with it by {reply_by}". `{reply_by}` is the note's reply-by date, but never earlier than 7
  days after this note is sent; a rejected credit is removal-due only from the day after the
  date ITS after-rejection note named.
- **A reply after an after-rejection note** (text or attachment; the latest user reply's
  own time is recorded per message, `last_reply_at`) holds the credits that note named for a
  human until a review rules on them again.
- **Held for a human** (`FILE.held`, counted in the run summary, never in FILE), each with its
  reason: a credit past its date whose document still awaits review (`document awaiting
  review`, including a credit the reviewer never ruled on), a credit whose user replied to the
  note in any way and no review has ruled on (`extension_requested_at`; the run summary also
  reports each newly recorded reply), and a rejected credit whose after-rejection note has not
  gone out, and a rejected credit whose user replied after its after-rejection note. A human
  picks them up with `--proof-review`.
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
  credits, Qobuz credits page, Apple Music credits, Discogs, AllMusic, MusicBrainz, Jaxsta).
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

Tests: `scripts/tests/intercom-verify-request.bats`, `scripts/tests/test_credit_verify_notify.py`.

## Enable gates (Fable decision 2026-10-17, `decision-verify-notify-enable-2026-10-17.md`)

Every gate holds the user for a human: no note, nothing closed, the credits are re-offered on
every later run (verify ledger `deferred_pending_doc` rows) and the held users are in the
daily line.

| Gate | Source | Missing source |
|---|---|---|
| Proof on file from any source (Intercom, support@ Gmail, core): no note at all | `/var/lib/credit-trust/proof-on-file.json`, through `credit_review.proof_parts` | no sends |
| Emailed support@ in the last 90 days | the same file's `gmail_contacts_90d` (`proof_parts.support_contacts`, the decider's reader) | no sends |
| Org affiliation (RULE-org-affiliation, schema `org-affiliation/v1` from cmux-credit-system-lane): a note needs verdict `none` with coverage `full`; no verdict, `held`, `labels_only`, `claimed_unverified` (automatic only for trusted-contradicted removals) or `contributor` / `verified_org` / `authenticated_domain` = human | `/var/lib/credit-trust/org-affiliation.json` (`credit_review.affiliation`, shared with the take-back gate); older than 2h or dated in the future = unknown for everyone | no sends |
| One ask per user per 90 days across verify-live and retro-past | verify ledger (`verify_ledger.asked_within`, checked in the run and again at the claim) | n/a |

Cadence: once a day at 09:00 Europe/Rome, paying users first, at most 200 messages a day for
the first week (then 500), reminders included and sent first. Removal, expiry and the
retro-past wave stay disabled (`RETRO_COPY_APPROVED=0`, `REMOVAL_COPY_APPROVED=0`, no expiry
job): `--removal-due` is a manual export only.

Full affiliation checks for the next recipients: after every decider apply run (production
ledger only), `credit-review.py decide` writes the account users of every verify-notify
candidate to `/var/lib/credit-trust/inputs/org-affiliation-priority-credit-trust-llm-t01.json`
(`{"user_ids": [...]}`); the producer's next hourly run checks them with coverage `full`.

