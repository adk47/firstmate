# GDPR erasure pipeline (`scripts/gdpr-pipeline.py`)

Fable's ruling `gdpr-ruling-for-jan.md` §3 as code, with the identity table of `gdpr-ack-v2-and-arpad-1101.md` §3.
Owner: cs-systemic lane. Jan is the human decision point only for identity code cannot establish, legal /
big-name / safety cases, and (with the captain) anything irreversible. Runs on node-8.

| step | what the code does | where |
|---|---|---|
| register | one `erasure_requests` row per request across Intercom (data-deletion tickets + conversation search), support@, notices@, legal@ and the markdown register's rows 1-39; `received_at`, `due_at` = received + 30 d, `hide_due_at` = received + 24 h, identity verdict + basis, hide PRs, `hidden_at`, `confirmed_at`; append-only `erasure_events` audit | `gdpr_pipeline/store.py`, `/var/lib/hydra-gdpr/erasure.sqlite` |
| confirmation replay | once a row carries a written confirmation the row is closed: the open ClickUp ticket and the Intercom conversation keep being re-ingested, so a replay with nothing new opens NOTHING. New pages are judged against EVERY row of that conversation (a reply that already opened its own row is not re-registered by a later "thanks"), and the new request is dated at the FIRST customer message that names one of its pages (`introducing_part_at`), never at the latest message — carrying only the pages no row of this conversation already covers. Never the original deadline, never an already-confirmed page. | `run.intake_clickup`, `run.merge_reply` |
| intake | row key per channel = the idempotence test (`intercom:<conv>`, `gmail:<alias>:<thread>`, `clickup:<task>`, `register:<n>`, `notice:<hash>`); ClickUp is a secondary index: a candidate joins a request on a shared key, or on a shared catalog id + requester email (never on ticket id alone); a merge only ever moves a due date earlier | `gdpr_pipeline/intake.py` |
| class | the customer's own words through legal-intake's `RULES` (read from `scripts/legal-intake.py`'s AST, never copied); a `cancel_intent` escalation filed as data-deletion is `not_erasure` (or Jan when it mentions deletion); data-export tickets are Art. 15 `privacy_access` rows (due date tracked, no hide) | `intake.ticket_class` |
| identity | **(2026-11-12: paths B and C below no longer pass. A name match is not a tie to the page; both answer `ASK_IDENTITY`. See the DSAR ladder.)** per page, from the core replica (claims, users), the admin catalog (name, claimed, popularity, credits, website) and the Intercom contact (identity_resolver r5 on `external_id`; the account email only when the address was delivered by mail or is an identified user): A claim · B account whose name matches · C unclaimed + name-fold match (sender name or email local part; at least two name tokens) **only for a VERIFIED sender — a ticket's requester-typed email is metadata, not proof, so an unverified ticket goes to ASK** unless popularity >= 60 or >= 50 credits (Jan) · D sender domain = the page's own website domain in our catalog (no freemail) · E representative -> ASK for authorisation · legal_threat -> hide first (captain) unless big-name · DMCA stays claim-first · a track / album passes only through its ONE catalog artist's profile on these same paths (`decide_item`; never an ASK, big item -> Jan). An 8-char prefix is resolved ONLY against the catalog (`resolve_prefixes`): a full id that happens to be in our rows/hide lists does not prove the prefix is unique, so an ambiguous prefix stays UNKNOWN and its pages are never attributed by guess | `gdpr_pipeline/identity.py`, `sources.resolve_prefixes` |
| hide | `hide-batch` plans identity-PASS profile pages, most overdue first, skips ids already in an open PR, and opens ONE H-DevOps PR (`HIDDEN_ENTITY_IDS`, prod + dev: 410 + noindex) and ONE platform-data-processing PR (`LEGAL_HIDDEN_ENTITY_IDS` + the strict-equality test's `ERASURE_PROFILES`, ref `gdpr-erasure-register-<n>`). A person merges. Only the anonymous 410 + noindex read-back (`mark-hidden`, every tick) sets `hidden_at`, per ELIGIBLE page (`hidden_pages`): a row that carries a PASS page next to an ASK / Jan page records its hide as soon as the PASS page is down, while a letter still waits for the whole row | `gdpr_pipeline/hide_batch.py`, `checks.public_gone` |
| confirm | for rows due within 3 d (or hidden): the approved letter (`erasure-confirmation-template.md`), lines S/P/M only from THIS run's checks (S: public autocomplete exact/lower/prefix; a FULL results page without the id is "cannot verify here" → `Unknown`, never "absent" — the endpoint has no paging, so a name with more matches than its cap can hide the target; P: 410 + noindex on /profile and /credits; M: every sitemap file walked, one unreadable file = no M line), `[D-no]` always, G never | `gdpr_pipeline/copy.py`, `checks.py` |
| asks | the approved lines only, verbatim: link line (no page), v2 step 1 (identity), authorisation line (representative). A row ALREADY past its statutory date carries the past-due opening line first ("the deletion request you made on {date} is in progress ...") because the ruling requires the letter to acknowledge the delay instead of reading as a fresh promise — and while `copy.PROGRESS_LINE_APPROVED` is False a past-due ask is **REFUSED** (ledgered, retryable), never sent missing that sentence and never sent with wording nobody reviewed | `copy.ASK`, `copy.progress_line` |
| **send** | ONE ledgered letter per request through the approved writers: `intercom-ops-write.sh reply --customer-facing --purpose gdpr-erasure` for a conversation, `gog gmail send --thread-id … --reply-all` from `support@muso.ai` for a support@ thread. The body is the approved copy byte for byte; `erasure_sends` holds `body_sha` + the writer's receipt, `UNIQUE(request_id, kind)` is the double-send guard, and the row is written `sending` BEFORE the writer runs | `gdpr_pipeline/send.py`, `erasure_sends` |
| watchdog | hourly tick pages #cs_priority (no person is named since 2026-11-12; the statutory clock goes to firstmate, see the DSAR ladder below) every open request at or past `due_at - 3 d` without `confirmed_at`, and identity ASKs unanswered > 7 d. The page fires per REQUEST, not per day-count: it is suppressed only for register numbers already paged today, so a request that becomes due the hour another one is confirmed is still paged. Each line carries the SEND FACT as well as the date (`no letter sent`, `no letter sent, N d past the deadline`, `letter failed`, `letter sent <date>`): "overdue" and "a letter went out" are two different claims, and on 2026-11-03 the line made only the first while 97 decided requests had no letter at all. When a row has no route at all, or the pipeline TRIED and the writer refused, the line names that and its reason (`no route for a letter (…thread is in a mailbox gog cannot write…)` / `the ask letter is refused (…)`): on 2026-11-04, 24 of the 141 approved letters were unroutable, and without the reason they read exactly like a broken pipeline instead of a missing mailbox auth. The route check is a pure capability test (`send.route`), so it names the blocker before anything has been attempted — the ledger only knows about attempts that happened | `run.watchdog_rows`, `erasure_sends` |
| gone pages | a page that answers 404 in the catalog AND publicly, with no merge record, was removed by something other than the hide process (the class of markdown register #36). `removed_outside_process` records those ids per row so the Jan item can cite the store instead of re-deriving it from the markdown; such a row is never hidden again and its letter waits for a person to say what was done | `run.decide_row`, `identity.GONE` |
| half-hidden pages | a hide needs BOTH lists — `HIDDEN_ENTITY_IDS` in H-DevOps drives the app-side hide, the PDP sitemap `legal_hidden` drives the 410 — and the two halves ship in **separate PRs**, so there is a window where the page answers 404 to the catalog and the public read while only one list holds it. `HIDDEN_PENDING` records that window and names which list is missing. Reading it as `GONE` files our own half-finished work as somebody else's deletion and sends it to Jan to explain; reading it as `ALREADY_HIDDEN` claims a hide that has not happened. It owes no letter either way. Measured live 2026-11-04: 9 open rows, all PDP-only, all waiting on the H-DevOps counterpart PR | `identity.HIDDEN_PENDING`, `sources.half_hidden`, `page_facts(..., half=)` |

## Hard rules

- **Never deletes.** No `DELETE /api/v3/admin/profile`, no muso-cli delete (legal hold 1350); a test greps the
  package for a DELETE path. Undo of a hide = remove the id from both lists.
- **The pipeline never hides by itself.** It prepares the batch PR; a person merges (captain standing order).
- **A page held for the captain's legal-threat call stays out of the routine batch**, even when a DIFFERENT register
  row decides that same page PASS. Rows share page ids in practice (register #126 and #246 both carry
  `7871c617-…`, withdrawn from an earlier batch for exactly this reason) and the batch dedups by page, so without this
  the second row would quietly overturn the withdrawal. `--include-legal` (the captain's GO) is the only way in.
- **"Already in an open PR" means the PR ADDS the id**, not merely that its head file contains it: the head hide list is
  read with the same parser the read-back uses and the PR's BASE file is subtracted, so a PR into a branch that already
  carries an id cannot suppress the batch that is supposed to add it. An unreadable file, a PR without a base sha, or a
  PR list at the scan cap claims nothing — a duplicate PR is the safe miss, a silently skipped hide is not.
- **Request text never selects a hide.** It only names which pages the request is about; each page is decided
  by the rules above. A mismatched name or someone else's claim is ASK. Text can only make a row MORE
  restrictive (representative wording -> ASK for authorisation), never less. A failed read is UNKNOWN, never a
  verdict, and the run exits 2.
- **Sends need three things, and the third is not a string this process can type.** (1) the compiled
  `copy.PIPELINE_SENDS_APPROVED` — a rollback flips it to `False` and every send refuses at once, no adapter change;
  (2) `--approved-by <Slack user id>`: one of the three people (Aaron / Jan / Nick) **or** the approved sender seat
  (`verify-sla-driver-fable-d2`, which posts through the DEVOPS bot — its id is that bot's `auth.test` user id, or
  `GDPR_APPROVER_SEAT` when set, never a name we were given). **This is the ledger's record of who authorized the
  batch; it is NOT who posts.** The Intercom writer is called in its `--purpose gdpr-erasure` mode, which carries no
  human id at all (see "The Intercom writer's purpose mode" below);
  (3) **an approval record, not chat text**: one top-level message in the approval channel (default #clio_devops,
  `GDPR_APPROVAL_CHANNEL` overrides, and a channel set to empty switches approvals OFF) that is EXACTLY
  ```
  APPROVE gdpr <kind> <digest> ruling=<ruling-id>
  ```
  Whitespace runs collapse and keyword case is forgiven; nothing else is. A refusal ("do not approve … yet"), a
  question, a quote, a code block, a paste, a chatty sentence or a threaded reply is a non-match by construction,
  which is why there is no negation word-list to get wrong. The `<ruling-id>` must exist in
  `policies/gdpr-send-rulings.json` with the same `kind` and an unexpired `expires` — so a new ruling is a reviewed
  commit, and an approval cannot name copy nobody approved. The `<digest>` is sha256 over the kind and every
  `(register, row, sha256(body), sha256(subject), sha256(recipient))` about to leave, so one changed letter, row,
  order or **address** invalidates it, and the approval is valid for `TTL_HOURS` (2 h). The dry run prints the **digest only** — never an accept string,
  because a pipeline that prints what the gate accepts manufactures its own approvals.
  - **The SCHEDULED path is a second, separate gate — a reviewed ledger entry, never a flag.** Fable decision 11-04
    B26 Q1 ("unlock both lines; the register sends on its due dates", under Aaron's 21:1xZ delegation and a 24 h veto)
    made the hourly tick a sender. A cron cannot post a 2-hour Slack approval per batch, so `tick --send` is
    authorised by `approval.verify_standing()` instead: a `policies/gdpr-send-rulings.json` entry with
    **`standing: true`** (an explicit field — a valid interactive ruling is NOT promoted by being valid), the same
    `kind`, an unexpired `expires`, its `not_before` passed (**that field IS the veto window**: the standing rulings
    start `2026-11-05T21:30Z`, so a veto is a ledger revert and arming needs no host action), `approved_by` equal to
    the identity running the tick (the devops seat, still resolved by `auth.test` — an id typed into a unit file is
    checked, not trusted), **`copy_sha` equal to `copy.fingerprint()`**, and **`classes`** naming the request classes
    it authorises. Both interactive requirements stay:
    `copy.PIPELINE_SENDS_APPROVED` and the sender identity. The interactive gate is a different function and the
    standing one cannot loosen it — a test pins that a live standing ruling still fails `approval.verify()` without
    the human's Slack message.
  - **Every one of those fields is REQUIRED, and an absent one refuses.** `not_before` and `approved_by` used to be
    checked only `if` present, which is the fail-open shape QA found on `#1779`: a standing ruling that simply omitted
    the veto window started sending the moment it merged, and one that omitted the approver could be executed by any
    identity. Absent is a refusal, never "already elapsed" or "anyone".
  - **A standing grant names the WORDS it was cut for.** It runs unattended for a month, so `copy_sha` binds it to
    `copy.fingerprint()` — a sha over every customer-facing constant in `copy.py` **plus the copy gates** (flipping
    `NEW_THREAD_LEAD_APPROVED` changes what a recipient receives without changing a string). Editing an approved
    sentence therefore invalidates the grant and the tick refuses until a PR re-cuts the value, which is printed by
    `gdpr-pipeline.py copy-sha`. The batch digest cannot do this job: it changes with every row, so it can never be
    written into a ruling.
  - **A standing grant names the REQUESTS it covers, not just the letter kind.** `copy.ASK` is erasure copy, and a
    `dmca_takedown` or `legal_threat` row reaches the same `ASK_LINK` verdict, so a kind-only grant told a
    rights-holder that "the deletion request you made on {date} is in progress" (QA finding on `#1779`; measured on
    the live register 2026-11-06: 5 `dmca_takedown` and 30 `legal_threat` rows carry `ASK_LINK`, 15 of them already
    past due, so the first unattended tick would have said it). Two independent gates now: `run.ask_refusal()`
    refuses the letter (`copy.ASK_APPROVED_CLASSES`, which is inside `copy.fingerprint()`), and `verify_standing()`
    refuses a batch carrying a class the ruling does not name. The scheduled pass **selects** by
    `approval.standing_classes()` before it verifies, so a mixed batch still sends its erasure letters instead of
    being refused whole — refusing the statutory breaches because a takedown notice shares the batch would be the
    opposite of fail-closed. Widening `classes` (or `ASK_APPROVED_CLASSES`) releases customer-facing copy, so it
    happens in the PR that carries that class's ruling, never as a bug fix.
  - **The scheduled pass is non-fatal by design.** By the time it runs, the tick has already done intake, decide,
    `mark_hidden` and the watchdog; a missing, not-yet-live or expired ruling skips THAT kind (naming which of the
    five conditions failed) rather than exiting and throwing away the hour's register work with it. `--limit` is a
    first-wave brake in the unit (25) and it counts **letters that reach a writer**, not rows examined: applying it to
    the selection let 25 permanently-refused rows (no `requester_email`, unapproved copy) occupy the window on every
    tick while row 26 was never attempted, even past its statutory deadline. A refusal or a skip does not spend the
    brake and stays in the queue, so the tick retries it the moment its cause is fixed. A sent letter keeps the same
    invariants as any other send: claimed
    `sending` before the writer runs, `sent` is final, an ambiguous failure is never retried.
  - **The digest covers the letter that actually LEAVES, and that is an ordering invariant, not a detail.** A letter's
    final body and subject are produced by `send.final_letter()`, and the CLI calls `send.materialise()` on the batch
    **before** `approval.verify()`. Hashing the pre-materialisation body instead would let the lead line and the
    subject change under a standing approval: the approver would have approved bytes nobody was going to receive.
    (`#1749` shipped that bug in its first cut; QA caught it.) So opening a copy gate — `NEW_THREAD_LEAD_APPROVED`,
    `NEW_THREAD_SUBJECT_APPROVED` — **changes the digest of any batch containing those rows, on purpose**, and the old
    approval stops matching. Measured 2026-11-04: the live 142-letter batch is `9f402f38a26acb2f` while the subject
    gate is shut, and `3539877f29da3ee0` the moment it opens (9 letters gain the lead line). A batch with no
    new-thread rows hashes exactly as before, so a hardening change cannot silently invalidate a standing approval.
  - **The RECIPIENT is part of the approved identity, not just the bytes.** A new-thread letter is addressed to the
    row's `requester_email`, which a later intake or a hand-edit can change; the body does not change when the address
    does, so a digest over body+subject alone let an approval cut for A authorise the identical letter to B — one
    person's erasure request, in our words, delivered to somebody else (QA finding on `#1749`). `send.final_letter()`
    therefore returns `(body, subject, recipient)`, `materialise()` records it on the item, `approval.digest()` binds
    it, and `deliver()` re-reads the route and **refuses** when the address it would send to is not the one the
    materialised item carries. Empty for every other route, so in-thread digests are unchanged — measured on the live
    store 2026-11-05: 144 letters, `b91c208e8750edc6` before and after, because that batch has no new-thread rows.
  - **Both copy gates are open as of 2026-11-04, and the subject one is CLASS-SCOPED.** The lead line's GO is
    `legal-finalize-fable-k1`; the subject's is `gdpr-support-from-1104` (firstmate 099), which approved
    "Your Muso.AI data deletion request" **for the deletion class only** and said an access/correction/objection row
    "stays refused until its own subject is written". So `NEW_THREAD_SUBJECT_APPROVED_CLASSES` names the classes whose
    subject has a GO — `privacy_erasure` alone today — and `copy.new_thread_subject()` raises `NoApprovedSubject` for
    any other class, naming the ruling it would need. The four-class vocabulary supplies the WORD; the GO supplies the
    right to SAY it. Widening that tuple releases customer-facing copy, so a class joins it in the PR carrying its
    ruling, never during a bug fix.
  - Fail-closed list, each with its own sentence: no bot token, no channel (empty = off), unreadable history, a scan
    that reached its cap, no such ruling, a ruling for another kind, an expired ruling, an expired message, a deleted
    message, a reply. The refusal always names what was actually scanned (how many messages, from whom, back to when).
  Nothing is composed: the copy is the approved template and ask lines, verbatim, and `body_sha` is ledgered with
  every letter.
- **A letter is claimed before it is sent, and an ambiguous failure is never retried.** `erasure_sends` is written
  (`sending`, with the letter's id: `sha256(request:slot:body_sha)`) *before* the writer runs, so a crash leaves a
  visible row rather than a letter the register does not know about. When the writer exits non-zero, times out, or
  the connection drops, we cannot prove the customer did not get it: that is `unknown`, it is paged, and **the
  pipeline never retries it** — a retry is how one request gets two statutory letters. Only failures that provably
  happened *before* the writer ran (no token, gog absent, thread unreadable/no subject) are `failed`, and those stay
  retryable in the same slot. That is why the two error types are separate classes in `send.py`, not one.
- **A wedged `unknown` row has an operator path, and it is audited.** `gdpr-pipeline.py resolve` is the only way a
  person moves a `unknown`/`sending` row: it requires a non-empty `--why` and a named person, it APPENDS the decision
  to `erasure_events` (`send-resolved`: from-state, to-state, why, who, the evidence it was decided on) instead of
  overwriting the writer's own `detail`, and it refuses a `sent` row (a letter that went out is not a question) and a
  `failed`/`refused` one (already retryable). `--all-refused` covers only rows whose evidence is a writer `REFUSED:`
  — every `refuse()` call site in `intercom-ops-write.sh` runs before the curl POST, so a refusal is provably
  pre-send and one shared reason is honest for the whole batch; anything else needs `--force` and an individual
  `--row`. `--all-refused --state sent` is refused outright. A `sending` row is resolvable only once its claim is
  older than `Store.SENDING_QUIESCENT_S` (900s): `sending` means a writer was STARTED and has not reported, so
  resolving it earlier makes the slot retryable while the original POST may still be in flight — two statutory
  letters to one person. The window is 20x the writer's own hard bound (`intercom-ops-write.sh` runs its curl under
  `timeout 45`), so past it the writer has provably exited and the row is an orphan; a test pins the two numbers
  together so the window cannot drift away from the thing it is derived from. Dry run unless `--apply`. Written for 2026-11-07, when
  114 rows sat in `unknown` — every one a `REFUSED:` — and the confirm batch was approved and delivered ZERO of 20
  because each row was blocked by an earlier claim nobody could clear.
  - **A writer REFUSAL is one of the provable ones, and it is read from the writer's own exit-code contract.**
    `intercom-ops-write.sh` documents 0 ok · 1 refusal · 2 usage/environment error · 4 post failed or wrong
    part_type, and its `refuse()`/`die()` are the only producers of 1 and 2 and are only ever called in the
    validation block ABOVE the POST. So a 1 carrying `REFUSED:` or a 2 carrying `ERROR:` proves nothing was posted
    and the letter is `failed` (retryable); a 4, a timeout, or a bare 1 (how `set -e` reports an unexpected failure)
    stays `unknown`. Getting this wrong is not cosmetic: on 2026-11-06 the first live send tick refused 40 letters
    (the sender seat is not on the writer's human allowlist) and every one was recorded `unknown`, i.e. permanently
    stranded. `gdpr-pipeline.py reconcile` is the repair for rows written before the distinction existed — it moves
    an `unknown` row to `failed` only when the recorded detail matches the pre-POST signature AND the register row is
    still open, and reports the rest as still a human's. It prints the `unknown` count before and after, so the
    repair is measured rather than asserted. **The tick runs it before it sends** (under the same `--send` guard), so
    a stranded letter heals on the next tick with no human step: the 2026-11-06 outage was not only the wrong state,
    it was that the repair was a command somebody had to remember to run.

### Recovering a missing requester address

A row with no `requester_email` cannot be answered at all: there is nowhere to open the new thread that a thread in
an alias mailbox needs. `gdpr-pipeline.py recover-addresses` reads the address out of a source the person themselves
supplied, in this order, and records it on the row:

1. **the Intercom conversation** — the email on a CUSTOMER-authored source message, else the contact's email;
2. **the Gmail thread**, read from the mailbox that owns it — but only when this host can actually read that
   mailbox, which today means `support@`.

Two rules make the answer honest rather than merely non-empty:

- **The sender is the first message in the thread that is not one of OURS.** Not the first message (11 support@ rows
  are threads WE opened, so their first message is ours) and not the last (a thread we replied to ends with our own
  address). Measured on the live register, 10 of the 19 addresses the first pass found were `support@muso.ai` —
  recording that as the requester would open the next statutory letter to ourselves, which is worse than having no
  address because it looks like progress.
- **A mailbox we cannot read is reported, never guessed at.** `notices@` and `legal@` are aliases for people, not
  accounts, so their threads are unreadable here and the row says so.

Measured on the live register, 2026-11-06: **100 open rows had no address; 9 were recovered; 91 genuinely have none
anywhere the pipeline can reach** — 54 in a notices@/legal@ thread (35 + 19), 13 Intercom conversations carrying no
email on the contact or the customer's message, 11 support@ threads that are entirely ours, and 14 rows with neither
a conversation nor a thread (11 support, 3 register). Those 91 are the only ones that still need a human.

### The Intercom writer's purpose mode

A statutory erasure letter is not a human request. It is an obligation with its own clock, and the writer's human
allowlist exists to stop a bot writing to the inbox as if somebody asked. So the writer has a **third identity
class**, not a fourth human: `reply --purpose gdpr-erasure`.

- **A purpose is a machine authorization the repo has already ruled on.** `PURPOSE_TABLE` in
  `scripts/intercom-ops-write.sh` is the whole list; a purpose not in it does not exist. Each purpose names the ONE
  identity it posts as (`system:gdpr-pipeline`), the ONE message shape it may use (`comment`), and the register that
  must OWN the conversation.
- **Ownership is checked in the writer, below the caller.** The writer refuses any conversation that is not an
  **open** row in `erasure_requests`. A bug in the pipeline therefore cannot widen the blast radius to the rest of
  the inbox. An unreadable register, or one with no `erasure_requests` table, is a refusal — never a pass. The
  ownership READ is read-only; the single-use claim CONSUME (below) is the one write the writer makes to
  `/var/lib/hydra-gdpr/erasure.sqlite`, and it touches only `erasure_sends.consumed_at`.
- **The BYTES are checked too, not just the thread.** Ownership alone would make the writer a general-purpose
  customer-facing poster for anyone who can run it: the human allowlist would be bypassed by a flag, and the only
  remaining gate would be "is this conversation in the register". So the body must match a letter the pipeline has
  **already claimed** — `claim_send` writes a `sending` row carrying the conversation as its target and the sha256 of
  the exact approved copy *before* it invokes the writer, so a matching row proves the pipeline composed this text
  for this thread under its own copy, standing-ruling and ledger gates. Arbitrary text has no such row and is
  refused. A `sent` claim does not match either: the letter is already out.
- **The claim is CONSUMED, atomically — a read-only check is not a claim.** Asking "is there a `sending` row" and
  then POSTing leaves a window: if the POST lands but the pipeline has not yet recorded `sent`, or two invocations
  overlap, the same check passes twice and the customer gets the same statutory letter twice. `UNIQUE(request_id,
  kind)` does not close it, because it bounds the PIPELINE's rows, not direct invocations of the writer. So the
  check is one conditional `UPDATE … SET consumed_at=… WHERE … AND state='sending' AND consumed_at=''` followed by
  `SELECT changes()`, and exactly one row must change. SQLite serialises writers, so of two concurrent calls exactly
  one wins and the other is refused. `store.claim_send` clears `consumed_at` when it legitimately reuses a
  `failed`/`refused` slot, so a real retry still works; a crash between the consume and `finish_send` leaves the row
  `sending` with `consumed_at` set, which is the correct "a letter may be out there" state and is never retried.
- **The consume runs LAST, after every no-write exit and every refusal.** `--validate` and `--dry-run` must not burn
  a claim: if they did, the no-write mode would succeed without POSTing, the real reply would then be refused, and
  an owed statutory letter would silently never go out. So `purpose_owns_conversation()` only READS, and
  `purpose_consume_claim()` runs immediately before the logged POST. A preflight refusal (leak scan, a missing
  `--customer-facing`, a bad flag) likewise leaves the claim intact, so a corrected retry still works.
- **`--purpose` is mutually exclusive with `--requested-by` and `--approved-by`.** The audit record must say what
  actually happened, and "a human approved this" would be a lie in the trail. The api-log entry carries
  `approved_by: system:gdpr-pipeline`, `requester: system:gdpr-pipeline`, `purpose: gdpr-erasure`, and an
  `authorization` line naming the register ownership that bounded it.
- **Why not just add the devops seat to the human allowlist** (the 2026-11-06 temptation): that would let the bot
  write to ANY conversation — every customer thread, not just the ones the register owns — and the log would still
  claim a human asked. Bigger blast radius, invisible in the trail.
- The ledger's `approved_by` still records the standing ruling's approver. That is the authorization chain and it is
  a different fact from who posted.
- **A confirmation has TWO letters and they get two slots.** An interim letter goes out while the pages are not yet
  off the public view ("the remaining step is in progress"); the final one says they no longer show the information.
  The interim is ledgered in `confirm-interim` and sets `interim_confirm_at`; only the final uses the `confirm` slot
  and sets `confirmed_at`, which is what takes the row out of the confirmation queue. With one slot the interim
  consumed it and the closing letter could never send. The deadline alert names which one happened — "interim letter
  sent …, final letter NOT sent" — because "no letter sent" while one is with the customer is the wrong fact.
  - **Every route fails closed.** A non-numeric conversation id, or a row with neither a conversation nor a thread,
    is REFUSED: the pipeline never opens a new thread with copy nobody approved.
  - **An unmeasurable host fact never picks the customer-facing route.** `gog auth list -j` failing (no gog, a 30 s
    timeout, unreadable JSON) is a THIRD state, not "writable": only the mailbox we SEND from may be assumed writable
    when we cannot ask (the writer is the backstop and there is no other route), so an unreadable discovery sends an
    alias-owned thread down the approved new-thread path instead of a doomed in-thread reply from support@ into a
    thread support@ does not own. When the owner is an alias the refusal names that PERMANENT reason, never the
    transient read — "we could not ask" and "the answer is no" have different fixes.
  - **Every letter is sent FROM `support@muso.ai`, whatever channel the request arrived on** (captain, 2026-11-06:
    "can you use support as your outbound channel please"). `legal@muso.ai` is an alias for Aaron and
    `notices@muso.ai` is an alias for Kyran — neither is an account this host can sign into, so there is nothing to
    send AS. `MAILBOX_BY_CHANNEL` is the send account (all three channels → support@);
    `THREAD_MAILBOX_BY_CHANNEL` is the separate fact of which mailbox OWNS a thread, and the two must not be
    collapsed: `route` needs the second to know a notices@/legal@ thread cannot be replied in, and `_mail_send`
    needs the first to know what to send as. The lead line still names the mailbox the PERSON wrote to, because that
    is the one sentence in the letter that has to be true.
  - **A thread in a mailbox we cannot write becomes a NEW thread from support@, not a refusal** — provided the row
    has a `requester_email`. With no address it still refuses, and the reason says the ADDRESS is missing rather
    than the mailbox: those are different problems with different fixes, and an operator reading the wrong one
    chases the wrong thing. For the two aliases the reason says "an alias for a person rather than an account"
    instead of gog's "auth it and the route opens", which is false advice for a mailbox that does not exist.
  - **Recovering a missing address never re-opens a claimed letter.** `recover-addresses` writes `requester_email`
    and nothing else; a row already claimed and `unknown` stays claimed and unknown, so a mailbox change can never
    become a second statutory letter to somebody who may already have the first.
  - **A dry run is the default** (`--send` is opt-in) and records `refused`/`dry run`, never `confirmed_at`.
    `--limit N` sends at most N, OLDEST deadline first (`oldest_first`), so a first live batch can be a canary.
- The search flags (`search_hidden` + `search_hidden_strict`, a catalog write) are not part of the batch; the S
  line is filled only when the autocomplete read-back shows the page absent. A malformed autocomplete response
  (no `data.items` list) is UNKNOWN, never "absent": a schema change must not put an unverified line in a letter.
- **A failed source read is never an empty source.** A missing/unreadable mail ledger, a support@ row with no
  usable `first_seen` or no thread id, and a failed Intercom search all fail the run (exit 2) instead of leaving
  the request unregistered while the tick exits green. The Intercom window is tracked by a cursor
  (`<store dir>/intercom-cursor.json`) that only advances after a clean search, so a timer outage is caught up on
  the next tick (capped at 30 days). The window is `created_at` OR `updated_at`, so a customer who replies
  "delete my data" to a thread from last month is found even with no ticket filed. That reply is dated at
  **its own** timestamp — the first customer part whose words match — so a request first made yesterday on a
  thread opened in October is due in December, not born overdue. The same rule applies when Caroline's ticket
  (not the search) is what brought the conversation in — with one qualifier: if the TICKET's own words already
  ask for the erasure (name, action summary, `customer_verbatim_request`), its earlier date stands, because that
  is when we were told. A bare label ("data deletion request") is not the request, so the reply's date wins and
  the row is never backdated to the day the label was made.
- **Watchdog state sits beside the store** (`_state_path`: the DB file's own directory, or the directory itself if
  one is passed), never the DB's parent: a page-suppression state file in the wrong directory silences a whole
  day of alerts.
- **The 24-hour hide deadline pages on its own** (`hide_due_rows`): a request whose `hide_due_at` (received + 24 h)
  has passed while its identity-PASS page is not hidden is posted as an overdue-hide page naming the register row and
  each pending page's own verdict, once per day. `ALREADY_HIDDEN` only means the id is in BOTH config lists, so it
  still pages (`listed, read-back pending`) until `hidden_at` — the 410 + noindex read-back — is set: a merged PR
  whose deploy failed leaves the page exposed and must never read as done. `GONE` (catalog AND public 404) does not. The batch PR stays a person's
  merge; this is the alert that keeps the deadline from passing in silence until the 30-day warning. It includes
  `LEGAL_HIDE_FIRST` rows (the captain owns the hide, not the alert), so an overdue legal-threat request pages too.
- **The page shows every due request.** The watchdog packs the lines into as many Slack messages as the length
  limit needs (40 lines maximum each) and nothing is discarded in the packing: a request counts as paged only
  when every message posted, so a 94-request backlog is all on screen — not 40 sent and the rest silently
  suppressed for the day.
- **In-flight is decided by the DIFF.** An open H-DevOps/PDP PR suppresses a hide-batch id only when the PR
  actually adds it to the list — the PDP dict entry `"<uuid>": (`, or the H-DevOps `value: "<uuid>,<uuid>…"` line
  (its list is one comma-joined YAML string, so a diff of it repeats the existing ids). A plan, a comment or a
  mention in a PR body suppresses nothing. In-flight is read from the PR's own HEAD FILE with the same parser the
  read-back uses (ids at head minus ids on main), so a comment, a reverted plan, the sitemap TEST file, or the same
  uuid under a different env var in the same manifest all suppress nothing; an unreadable head claims nothing.
  Checked against the live #4624 / #2575 heads: 47 of 47 in each half.
- **A written confirmation closes reconciliation.** A later look-alike (same email + page, or the same notice in
  another mailbox) becomes a NEW request with its own due date and its own watchdog, never a merge into the
  finished row. Key-based idempotence is unaffected: the same conversation or ticket is still the same request.
- **The store migrates, it is not recreated.** New columns are added by `store.migrate()`; the rows are the
  legal record.
- **`backfill` is additive, and is NOT a way to rebuild the register.** It never deletes a row, so re-running it
  against the live store is safe. But it cannot *reconstruct* one: a fresh bootstrap sees only what the sources
  still return inside the Intercom lookback window plus whatever the `--register` file lists. Measured on
  2026-11-04: a from-scratch backfill produced **273** rows where the live register holds **374**, a strict
  subset — the 101 extra are 79 Intercom tickets older than the lookback, 19 notices@/legal@ tickets, and 3
  register rows. Anyone treating backfill as the source of truth would therefore drop 101 statutory requests
  silently. The register is the record; the sources are only how rows arrive.

## The DSAR ladder: acknowledgement, status updates, the clock (`gdpr_pipeline/dsar.py`)

Captain, 2026-11-12: a GDPR request is handled end to end by the machine, never routed to a named person. Measured
baseline and the findings behind this section: `data/gdpr-ai-handling-v1/baseline.md`, `report.md`.

Scope: `privacy_erasure` and `privacy_access` only. A `legal_threat` or `dmca_takedown` row gets no ladder message
(captain 2026-11-10: no legal letters).

| piece | what it is | where |
|---|---|---|
| state | `received -> identity_check -> in_progress -> responded -> closed`, DERIVED from recorded facts on every run and written to `dsar_state` with a `dsar_state` event on each change. Nothing sets it by hand, so it cannot drift from the record. `responded`/`closed` exist only once the final response is recorded: the row's `confirmed_at`, or a `sent` final letter (`confirm`, `access`) in the send ledger (`dsar.final_response_at`; 7 open requests on the live register had the ledger row and no stamp, and each would have been told "we are late" for an answer it already had). A request cannot close without one. A register row closed by hand with no response is listed by the clock as an anomaly | `dsar.state_of`, `Run.dsar_states` |
| the date | the EARLIER of one calendar month (clamped to the month's end) and receipt + 30 days, so the stated date is never later than either reading of "one month". `extended_until` moves it, bounded at three calendar months from receipt; only a SENT extension notice writes it (`Store.apply_effects`; see "The three decisions" below). The register's `due_at` column is unchanged | `dsar.statutory_due`, `dsar.due` |
| identity chain | captain's ruling 2026-11-12, recorded per row in `gates`: (1) account control: signed in, or controls the account's email; (2) a tie to the page: the page is claimed by that account, or the verified sender's host is the page's own catalog website; (3) an authority document only where 1 and 2 leave a real doubt. **A name match is not a tie** (paths B and C no longer pass; they answer `ASK_IDENTITY`), and **no message asks for a passport or any identity document** (GDPR Art. 12(6) allows asking for more only on reasonable doubt). A page that is already hidden or gone ties nobody: it is recorded as `hidden` / `gone`, never as a gate-2 pass (the first live dry run counted 40 passes of which 12 were claims). An 8-char id prefix that no page carries is a link to ask for only when the catalog lookup ANSWERED; a lookup that failed is `unknown` and is re-read. The chain yields ONE `need`: `none`, `claim_or_authority`, `link`, `authority`, `account`, `unknown`. A request not yet through the chain (`gates.v` absent) is owed no message: nothing claims to know what it needs, and the clock still names it | `dsar.gates`, `run.decide_row`, `identity.decide_page` |
| acknowledgement | one per request, while the date is at least 3 days ahead (`ACK_MIN_RUNWAY_DAYS`: live request #52 would have been promised an answer "by 12 November" one hour before that date; nearer than that it gets NOTHING until the date itself, because "we are late" is not true yet; the clock names it throughout and the late update is owed the moment the date passes): the date we received it, the date we answer by, and the one thing needed. Claim-then-request is stated here: "claim the page, or send a document from the artist's label or management". It replaces the older identity ask for a statutory request (`Run.asks` stands down once the ladder has authored a message for the row), so nobody is asked twice for two different things. Whether a first message already went is read from the send ledger as well as the row's stamp (23 live rows carry a `sent` ask and no `ask_sent_at`), and a letter that may be out (`sending`/`unknown`) counts | `dsar.owed`, `dsar.first_contact_made`, `policies/gdpr-dsar-copy.json` |
| status update | at the halfway point (if nothing was said in the last 7 d), and for a request past its date: every 14 d, promised by date in the message itself (`next_contact_at`), sent a day before the promise runs out. A late update says we are late and sorry, once, and gives no reason. Where we need nothing from the requester it states the date they will have the answer (today + `LATE_ANSWER_DAYS`, 14), recorded as `answer_promised_at` when the message is sent. That date is stated only for an answer code alone can produce today (`run.answerable_now`: an erasure whose every named page is already hidden; an access request only while `access.standing_gaps` is empty). Any other late request with nothing needed gets `late_none_no_date`, which states the next contact date and no answer date (firstmate: "no promise we cannot hold"); the clock names any request whose stated date has passed (`promises_missed`). Where we are waiting on the requester it states the next contact date only. Slots `status`, `status-2`, ... keep one letter per slot | `dsar.owed`, `dsar.next_status_slot` |
| copy | written by the model, committed with its provenance, and FIXED per variant: code fills three dates and nothing else. No name, no link, no free text reaches a body, so the text under review carries no personal data. A code lint (barred words, unfilled slots, the deadline present, the requester's name or email absent) runs before a body is ever queued | `policies/gdpr-dsar-copy.json`, `dsar.render`, `dsar.lint` |
| the copy gate | **no verdict, no send.** Each authored body is frozen in `dsar_messages` with its sha256, and `send.deliver` reaches a writer only when `scripts/outbound_copy/gate.py check` answers rc 0 `approved` for exactly those bytes and exactly that subject line (empty or not), under the `gdpr` rubric family, with a verdict id and statement hash to record. Pending, refused, rewrite, a wrong rubric, a hash that differs, a gate that is not installed, times out or prints nonsense: all a hold, ledgered `refused` with the reason and retried next tick. The gate's path is derived from this file's location; there is no flag and no environment variable that skips it. `approved_by` on the send row is `gate:<verdict id>` | `gdpr_pipeline/copy_gate.py`, `send.deliver`, `policies/outbound-copy-rubric-gdpr.md` |
| the clock | every statutory request inside 7 d of its date or past it, oldest first, with its state, what it needs, the last message and why a message is held; and every statutory request nobody has written to 48 h after it arrived (`NO_FIRST_MESSAGE_HOURS`), whatever the reason. The line names EVERY one of them, however many (it once named 12 and said "and N more"); a request in both lists is named once. Two things run it. `gdpr-dsar-clock.timer` on node-8 (installed by the deploy) reads it every hour (`dsar clock --watch`: the line goes to the journal). Firstmate's check `scripts/gdpr-dsar-clock-check.sh` pulls it every 5 minutes (`dsar clock --line --read-by firstmate --reader-sha <its own sha256>`) and wakes firstmate with the line when the set of named requests changes, and once a day while it is not empty. node-8 has no route into the firstmate box, so the read is a pull, and the check is put into a firstmate home by this repository's own `scripts/gdpr-dsar-clock-register.sh` (install + bind to its bytes; `--check` says whether a home has THESE bytes; `--unregister` retires it; the id `a0-gdpr-dsar-clock` sorts first because the watcher runs checks in name order and ends a sweep at the first with a line). Each read leaves a mark and the sha256 of the check that made it, and the hourly unit pages, once a day, when requests are named and either the mark is over 26 h old or the reading check is not the one deployed (`dsar.clock_unread`): a home never registered, stopped, or registered before the check changed is loud on the other side within the hour. The Slack due-date page (`Run.watchdog_rows`, `tick --page`) carries a statutory request from the same 7 days out, once a day; it is a record, not the alarm. None of them names a person | `dsar.clock_rows`, `dsar clock --line`, `dsar clock --watch` |
| the first message | due 24 h after the request arrived (`FIRST_REPLY_HOURS`). Three things kept a request from one, and each is closed in code: a statutory row with no identity chain (`gates.v`) is decided on the next tick, not at its 20 h refresh; a row whose identity reads failed gets a chain that says `unknown`, so it is owed `ack_unknown` instead of nothing (`Run.chain_unread`; it never replaces a chain a real read wrote and makes no decision); a statutory row closed with no final response on record is reopened before the tick decides (`Run.reopen_unanswered`, event `reopened`), and the markdown register cannot close one. Which message is owed is unchanged: the acknowledgement while the date is 3 d or more ahead, the late update once it has passed. Every ladder send writes a `dsar_sent` event with `received_at`, `statutory_due_at`, `sent_at` and, for a first message, `first_reply_due_at` and `first_reply_late_hours`; `dsar clock --json` lists `first_reply_overdue` beside the 48 h `no_first_message` list the line still pages on. A request with no route (no conversation, no thread, no address) is still refused at send and still named by the clock | `dsar.first_reply_due`, `dsar.send_dates`, `Run.decide_all`, `Run.reopen_unanswered` |
| the trail | `dsar trail --request N` rebuilds, from the store alone: what was received and when, the identity chain as decided, every authored body with its sha256, copy-file hash, gate result, verdict id, statement hash, reviewer and time, every send attempt with the writer's receipt, and every event | `Run.dsar_trail` |

```
gdpr-pipeline.py dsar plan --bodies          # what each open statutory request is owed, exact bodies; reads only
gdpr-pipeline.py dsar author                 # freeze the bodies and put each up for review; sends nothing
gdpr-pipeline.py dsar send --limit 5         # author, then send what the reviewer approved
gdpr-pipeline.py dsar clock [--json|--line]  # the statutory clock
gdpr-pipeline.py dsar clock --watch          # what gdpr-dsar-clock.timer runs: the line, and the unread page
gdpr-pipeline.py dsar extend --request 216 --evidence "..." --ruling ID   # record the NEED for an extension
gdpr-pipeline.py dsar trail --request 468    # one request's whole record
gdpr-pipeline.py tick ... --ladder --ladder-limit 25    # what the hourly unit runs
```

Kill switch for the ladder alone: `/etc/hydra/gdpr-dsar-ladder.disabled` (nothing is authored or sent; the clock and
the rest of the tick keep running). `/etc/hydra/gdpr-pipeline.disabled` still stops everything.

**The three decisions (firstmate, 2026-11-12T07:09Z; recorded in the rubric and in `dsar.EXTENSION_RULING`).**

- *Lateness.* A request past its date is told so: late, sorry, the date. No reason, no cause, no admission
  (`late_*` variants; `dsar.lint(late=True)` refuses a late update with no apology and an apology anywhere else).
- *Extension (Art. 12(3)).* `extension_number` is selected only when ALL hold: a NEED for the extra time is
  recorded against the request with the ruling that found it (`dsar extend --request N --evidence "..." --ruling ID`
  writes `extension_need` and `extension_need_ruling`; it sends nothing and moves no date), code cannot send the
  answer today (where it can, the answer goes and no time is needed), the requester has at least
  `EXTENSION_MIN_REQUESTS` (2) open statutory requests, we need nothing from them, no extension is recorded, and the
  date is still ahead and inside 7 days. How many requests a person has and how near the date is are a ground and
  a timing, not a need: on those alone no date moves (QA review of #1908 found two already-answerable requests
  would have been sent notices). The new date is one further month, never past three calendar months from
  receipt. It quotes the rule and names the ground. A request already past its date never gets one: an extension
  must not cover lateness. The date moves only when the notice has been SENT. `extension_complexity` is
  `"enabled": false`: complexity is the rule's other ground and no code can measure it.
- *Refusal (Art. 12(4)).* `denial` is `"enabled": false` and nothing selects it. The default is to comply. A
  request we cannot yet connect to a page is asked for what is missing, never refused.

A host with no copy gate holds the ladder (`dsar ladder: held, the copy gate is not installed`): authoring would
make the older ask stand down and leave a new request with no first message. It resumes when the gate appears.

The older ask stands down ONLY where the copy gate holds a letter that is going to THAT request. One table decides
it, `dsar.OLDER_ASK_STANDS_DOWN`, keyed by what `dsar.ladder_letter(row, sends, msgs)` finds for the one request
(asked when the batch is listed and again by `send.deliver` on the row as it is at send time). Every answer the
gate can give is a row, the ask kind is not an input, and there is no run-wide flag (it once stood down for every
statutory request whenever the ladder had run):

| the ladder's letter for this request | the older ask | why |
|---|---|---|
| `sent` (out, or `sending` / `unknown`: may be out) | stands down | it would be a second first message |
| `approved` (the gate approved these exact bytes) | stands down | the letter goes on this send |
| `pending` (in the review queue) | stands down for at most 24 h (`FALLBACK_HOURS`) from the request's first authoring, then proceeds | the one case where the gate holds a letter not yet decided; a queue nobody is working delays first contact by a day, it does not end it |
| `refused` (the reviewer said no) | proceeds at once | no letter is coming |
| `error` (the gate could not answer: not installed, timed out, unreadable, or an answer this code does not know) | proceeds at once | the gate holds nothing for this request |
| `missing` (authored, no gate answer on record) | proceeds at once | nobody is reviewing it |
| none (the ladder owes it nothing now, or is held or killed on this host) | proceeds, exactly as before the ladder existed | other requests' letters change nothing for it |

With several held letters for one request, it waits only while one of its own is `pending`. Once an ask has gone,
no acknowledgement is owed (`dsar.owed`): one first message, not two. One test per row: `OlderAsk` in
`tests/test_gdpr_dsar.py`, and `test_each_gate_verdict_decides_the_older_ask_for_the_request_it_is_about` through
the store.

"Proceeds" means the ask is LISTED and takes its existing approval path, where its words are a separate question
with its own recorded answer (`run.ask_refusal`, a `refused` row in `erasure_sends`, never a row left off the
list): a class with no approved ask copy is refused there, past-due copy was until it was approved, and so is the
identity step (`ASK_IDENTITY`, `dsar.ASK_WORDING_SUPERSEDED`) for a statutory request. Its approved sentence says a
name "as it appears on your ID ... is enough"; under the 2026-11-12 ruling a name match ties nobody to a page and
no code path passes one, so the letter would promise what the next step refuses. The sentence is part of
`copy.fingerprint()`: changing it voids every standing ruling, so new words arrive with their own ruling, not in a
fix. Until then such a request's first message is the ladder's reviewed acknowledgement
(`ack_claim_or_authority`), it is named in the clock line after 48 h with no message from us, and the refusal is
on its trail. A statutory request with no ask kind at all (an identity PASS, and every access request: the ask copy
is erasure copy) has only the ladder's letter, and that one never sends without the gate's approval.

A held body is kept while it is still TRUE, so the hash under review is the hash sent (`dsar.stale`). It is
authored again, and reviewed again, when the message owed is a different one, when a date it states has moved (a
request folded into an earlier one, an extension), when the wording in the copy file changed, or when a late
update's promised date is under 3 days away.

**Not built here.** (1) A store and a coded check for an authority
document (gate 3): one that arrives is read by nobody in code, and the request stays named by the clock. (2) A track or album page that
does not pass through its one artist's profile stays `JAN_REVIEW`, which the chain reads as `unknown`: there is no
coded ask for an item page, so that request gets the "we are checking" wording and stays named by the clock. (3) The
erasure confirmation and the older ask keep their existing approval path: the confirmation's body carries the
requester's name and page links, so a reviewer outside node-8 cannot be shown its exact bytes without moving personal
data off the box. That needs the reviewer reachable inside OVH.

**Where the reviewer runs.** node-8 has no route to the reviewer model (`data/gdpr-ai-handling-v1/report.md`,
finding 1). The gate (lane `outbound-copy-fable-gate-v1`) holds each body on node-8 as pending; a reviewer host pulls
the pending bodies, signs a verdict over the body hash and the rubric hash, and node-8 verifies the signature against
`policies/outbound-copy-reviewer.allowed_signers`. Until that gate is deployed, every ladder message holds.

## The Art. 15 answer: the copy of the data (`gdpr_pipeline/access.py`)

GDPR Art. 15(3): "The controller shall provide a copy of the personal data undergoing processing." For an access
request the copy IS the final response; nothing else takes the request to `responded`.

| piece | what it is | where |
|---|---|---|
| whose data | the account the requester controls NOW (gate 1, re-read at build and again at send: `sources.resolve_account`). No account control, or written on someone else's behalf: nothing is built, and the reason is returned | `Run._access_account`, `run.requester_of` |
| what is read | every row keyed to that account (by account id, or by the sign-in address for the tables that hold only an address) from each table in the manifest, on the read-only replica. One query per table, bound to the one account | `policies/gdpr-access-sources.json`, `access.read_source` |
| what is left out | columns the manifest withholds, each with a stated reason: `credential` (sign-in secrets and tokens) and `another_person` (a field that identifies someone else; the reason quotes Art. 15(4)). A withheld column is never read at all. A secret-looking column nobody has ruled on is withheld as `unreviewed` and makes the copy incomplete | `access.columns_of` |
| complete, or not the answer | the copy is `complete` only when every source read, the replica shows no account-keyed table the manifest does not know (`access.unclassified`), every system in `systems` is covered, the Art. 15(1) information has recorded text, and the included columns have been reviewed (`column_review`). A source that did not read is `unknown`, never an empty list. An incomplete copy names each gap and is never sent | `access.collect` |
| the bytes | canonical JSON (sorted keys, no clock, no run id): the same data gives the same sha256. `--record` writes it beside the register (`access/`, 0600 in a 0700 directory) and puts the hash and counts on the trail. Counts only reach a log, the trail or stdout; never a value, never an address | `access.package`, `Store.put_access_answer` |
| delivery | sent only when ALL hold: the newest recorded copy is complete, the file is the recorded bytes, it is under 24 h old, it is no larger than a mail attachment takes (`access.ATTACH_MAX_BYTES`, 18 MB; a larger copy is held with that reason, and no other delivery route is built), the requester controls that account now, and the cover message has a verdict on its exact bytes (campaign `gdpr-access`). The only recipient is the sign-in address ON THE ACCOUNT, never the address the request was written from, and it is READ AGAIN at send (`sources.account_email`): the copy carries the address as it was at build, up to 24 h earlier, so an address that has changed since, or one that cannot be read now, holds the copy until it is rebuilt. One send per request, claimed before the mailer runs; an ambiguous failure is `unknown` and never retried. The send stamps `confirmed_at` | `Run.access_deliver`, `access.undeliverable` |

```
gdpr-pipeline.py access build --request 222             # reads only; prints counts, the hash and every gap
gdpr-pipeline.py access build --request 222 --record    # also writes the copy beside the register
gdpr-pipeline.py access deliver --request 222 --dry-run # every reason it is held, or what would be sent
gdpr-pipeline.py access deliver --request 222           # send it (held by the ladder kill file too)
```

**Every copy is incomplete today, on purpose, and so none can be sent.** Three things in the manifest are open:

1. `information_notice.text` is empty. Art. 15(1)(a)-(h) requires the purposes, the recipients, the retention
   period, the rights and the source to be stated with the copy. That text is a legal statement; it is recorded by
   a reviewed change to the manifest, not written by this code.
2. `systems` lists nine systems that hold personal data and are not read yet (support conversations, support
   mail, the payment processor, the sign-in provider, marketing mail, in-app messages, proof documents, tickets,
   analytics). The list was written from the repository, not from a data map, and is not verified to be complete.

3. `column_review.reviewed` is false. The withheld list was written from column NAMES; nobody has read what the
   included columns hold, and a free-text or JSON column can carry another person's data (Art. 15(4)).

Nothing runs this on a timer: `access build` and `access deliver` are per request. A new account-keyed table in the
core schema makes every copy incomplete until the manifest reads it or sets it aside with a reason.

## Commands

```
gdpr-pipeline.py backfill --register removal-erasure-register.md --out backfill.md   # once
gdpr-pipeline.py tick --page                 # hourly (gdpr-pipeline-tick.timer, install-aux-units.sh)
gdpr-pipeline.py hide-batch                  # dry run: prints both diffs
gdpr-pipeline.py hide-batch --open-prs       # opens the two PRs (records them on the rows)
gdpr-pipeline.py confirm --sitemap           # renders the letters due within 3 d with verified lines
gdpr-pipeline.py ask                         # renders the identity asks
gdpr-pipeline.py ask --manifest batch.json   # renders EXACTLY the approved rows (frozen batch; see below)
gdpr-pipeline.py report --out register.md    # the register table
gdpr-pipeline.py dedupe                      # report post-confirmation rows that are one customer event
gdpr-pipeline.py dedupe --apply               # close the duplicate, keys re-pointed at the row kept
gdpr-pipeline.py reconcile                     # report `unknown` letters the writer refused BEFORE posting
gdpr-pipeline.py reconcile --apply             # make the provable ones retryable (`failed`); the rest stay `unknown`
gdpr-pipeline.py recover-addresses             # report the requester address for open rows that have none
gdpr-pipeline.py recover-addresses --apply     # record the recovered ones (never touches erasure_sends)
gdpr-pipeline.py intake --candidate -         # record ONE request pushed by another producer (see below)
```

### An approval binds a FROZEN batch, not "whatever is open at send time"

The approval gate hashes the rendered letters (`approval.digest`), so a batch is approved by digest. That only means
something if the digest names a fixed row set — and `--limit N` does not: it takes the oldest N of whatever the
register holds *now*, so the next hourly intake re-cuts it.

That is not theoretical. On 2026-11-04 a 141-letter ask batch was approved as `2ac206a275d2b0d2`; the deployed
`gdpr-pipeline-tick.timer` then created register **#381** from a new Intercom ticket, and the same command rendered
142 letters with digest `9f402f38a26acb2f`. The approval no longer named anything sendable and the send refused —
correctly, and the correct response was NOT to re-approve whatever was open.

`--manifest FILE` names the rows instead. Two entry forms:

```
[329, 323, 58]                                                  register numbers, cut from a dry run
[{"request_id": "<row>", "register_no": 329, "body_sha": "…"}]   a PINNED batch file: row + the exact body it was
                                                                approved with
```

and one register number per line also works (`#` comments allowed).

```
gdpr-pipeline.py ask --manifest batch-1104.json          # dry run: digest only, as always
gdpr-pipeline.py ask --manifest batch-1104.json --send --approved-by U0AN41ZBTRU
```

- the digest is computed over **exactly those rows**, so intake after the approval lands in the next batch;
- order is still statutory (`oldest_first`); a row named twice still renders one letter;
- **it fails closed, exit 2**, if any manifest row is not in the sendable set now (closed, already sent, verdict
  changed, or a typo). Sending the remainder would be a *different* batch under the same approval;
- in the pinned form, a letter whose **body** no longer hashes to the pinned `body_sha` also refuses: copy is
  approved per body, so a copy edit is a fresh approval and never a re-cut;
- an empty, unreadable or unparseable manifest refuses, as does `--manifest` together with `--limit` (two selectors,
  no defined winner);
- **a file that MIXES the two entry forms refuses.** They guarantee different things: a bare register number is not
  copy-checked, so it cannot ride an approval whose other rows are pinned by body hash. Before this was caught, a
  manifest naming `250` *and* a `request_id` rendered only the `request_id` one — a silently short list under a
  longer approval, which is exactly the failure the pinned form exists to prevent;
- **a `request_id` entry without `body_sha` refuses too**, for the same reason: it looks pinned but would skip the
  copy-change check, so an edit after the GO would ride the old digest. Pin every row or name every request by
  register number — not part of each.

**The re-cut rule the approver gave (2026-11-04), now enforced here rather than remembered:** a batch whose digest
changes only because *intake added rows* (no removals, no body change, same kind, same copy ref) carries the existing
GO once the delta and the new digest are posted; **any removal or body change needs a fresh approval**. Pin the batch
you were granted and the rule never has to be applied by hand.

Cut a manifest from a dry run, and re-render immediately before sending: `--manifest` is what makes that safe, so the
digest to quote to the approver is the one the manifest produces, never the one an unfiltered run produces.

### Accepting an erasure found by another producer

The notices@/legal@ reader (`scripts/legal-intake.py`) and any future listener hand requests over instead of keeping
them in their own table. Two ways, both idempotent on the row key:

- **Push (preferred — synchronous, returns the verdict):**
  `gdpr-pipeline.py intake --candidate request.json` (or `-` for stdin, one object or a list). Prints the register
  number, the dates it derived, and the identity verdict + next action, so the caller learns what will happen in the
  same call rather than waiting up to an hour for a tick. `--no-decide` records only.
- **Ledger (batched):** write the row into the shape `--gmail-ledger` / `--support-ledger` already read
  (`alias`, `class`, `thread`, `first_msg`, `ids`, `notice_key`, `replied_by_us`), and the tick picks it up.

The candidate is ids, never bodies:

```json
{"keys": ["gmail:notices@muso.ai:1a1a436083a51047"], "channel": "notices",
 "class": "privacy_erasure", "received_at": "2026-11-04T01:39:22Z",
 "gmail_thread": "1a1a436083a51047", "requester_email": "someone@example.com",
 "pages": [{"entity": "profile", "id": "fc31a861-0297-410d-914b-60e8a02ced76"}],
 "note": "notices@ name removal"}
```

- `keys` — the FIRST is the row key and the idempotence test: `gmail:<alias>:<thread>`, `intercom:<conversation_id>`,
  `clickup:<task_id>`, `register:<n>`.
- `received_at` — **the email's own date**, ISO-8601 `Z`. Both clocks are measured from it: `due_at` = +30 d (the
  written confirmation) and `hide_due_at` = +24 h. A row dated by when we noticed it is a row whose legal clock
  started late.
- `class` — only what the register can *act* on: `privacy_erasure` (a deletion/name-removal request, or an objection
  to a public listing — identity check, hide-eligible), `privacy_access` (Art. 15 export: a row and a due date, no
  hide), `legal_threat`, `dmca_takedown`, `cancel_intent_mentions_deletion`, `not_erasure`. There is no
  `objection`/`name_removal` class, and inventing one is a copy+identity decision, not a field value: a row carrying a
  class the pipeline does not know would be created and then filtered out by every pass — "registered" to the sender,
  watched by nobody.
- `pages` — catalog ids only (`{"entity": "profile"|"track"|"album", "id": ...}`, full uuid or the 8-char prefix the
  mail ledgers carry). No ids = no hide; the row lands on the link ask (`ASK_LINK`).

Anything the register cannot act on is **refused loudly** (exit 1, the known list in the message): an unknown class, an
unknown field, a non-ISO date, an empty/invalid `keys`. Same for the ledger path — an unknown class in the notices@/
legal@ ledger is now a source failure that fails the run (exit 2) instead of a row that silently vanishes.

A MANUAL run on node-8 needs the environment loaded **exported**: `/etc/openclaw/main.env` is plain `KEY=value`
lines, so a bare `. /etc/openclaw/main.env` leaves the Trino/Intercom/admin variables unset in the child python
and the run fails closed with a wall of `no Intercom token (MUSOAI_INTERCOM_TOKEN)` / `MUSOAI_API_URL not set`
errors (systemd is unaffected — `EnvironmentFile=` exports natively). Use:

```
set -a; . /etc/openclaw/main.env; set +a        # the env file does not `export`
/opt/hydra/scripts/gdpr-pipeline.py tick --page
```

**One live batch pair, always the whole set.** Each repository has ONE pipeline PR (`gdpr-pipeline/hide-*`), and it
carries everything the register wants hidden that `main` does not have yet. A run whose open PR already adds exactly
that set touches nothing, so a pending review stays valid. When the set changed, or GitHub reports the open PR as
conflicting with `main` (the hide list is one line, so any other merge to it does that), a NEW PR is opened from `main` with
the whole set and only then is the old one closed with a comment naming its replacement: never a force-push (an
approval must not ride onto ids its reviewer did not see) and never a branch delete, so `gh pr reopen` undoes the
close. A routine run keeps the legal-threat ids an `--include-legal` run already put in the open PR and never adds one
itself. If what an open pipeline PR adds cannot be read, that repository is left alone and the run exits 2. A
hand-written hide PR (a different branch) is somebody else's: its ids are left out of the batch.
This replaced "defer while a pair is unmerged" (both PRs insert at the same point of the same file, which is still why
there is only one): deferral was per repository and left the two repositories permanently out of step (11-10 / 11-11:
H-DevOps #5105 waited on PDP #2582 while PDP #2583 waited on #5105), so an id's two halves were never open together.
The batch runs at 00:20, 06:20, 12:20 and 18:20 UTC.

**A track or an album goes through the same identity gate** (`identity.decide_item`, facts from
`sources.item_page`): the item's artists are read from the catalog, and it passes only with EXACTLY ONE artist whose
profile passes `decide_page` for this requester and class. Popularity >= 60 on the item goes to Jan on every path;
two artists, a missing artist, an untyped field, a deleted artist profile or a part id stay `JAN_REVIEW`; an item never
produces an ASK (the ask copy is about a profile). The platform-data-processing test needs its `ERASURE_ITEMS` set
first; until then an item is prepared in neither repository and the run prints `blocked`. Patch, shadow numbers and
the undo table: `docs/support/caroline-billing-and-hide.md`.

One run at a time: every writing run takes `flock` on `<store dir>/run.lock` and a second run exits 0 having done
nothing (the tick is minutes long by design — each decide pass is ~5 network reads per stale row, and every Trino
query is a `kubectl exec` — so two overlapping ticks only double the load and can page twice for one row).

**A tick takes on the order of 15-20 minutes** (measured 19m for 246 open rows, ~20 min of it in the decide pass), which
is why `gdpr-pipeline-tick.service` carries `TimeoutStartSec=3000` — a manual `timeout 1200` around it kills a run
that is working normally. Read a tick's cost as network reads, not code: `resolve_prefixes` alone is one Trino query
per 60 prefixes (~50 s for the current 31), and each page costs a catalog read plus an anonymous public GET.

**One customer event = one request, whichever key saw it.** A post-confirmation request is keyed
`<parent row key>:again:<message time>` on the confirmed row's own canonical key, and a second arrival through a
different key of the same row reuses it. `dedupe` is the repair for rows minted before that rule (the live register
carried a `register:19:again:<at>` / `gmail:legal@…:again:<at>` pair: two deadlines, two watchdogs and two letters for
one message); it is a report unless `--apply` is passed.

**The two deadlines page separately**: the 24-hour hide page and the `due_at - 3 d` confirmation warning are tracked
per register number AND per kind (`hide:<n>` / `confirm:<n>`), so an overdue-hide page never suppresses the
statutory-date warning that becomes due later the same day.

Kill switch: `/etc/hydra/gdpr-pipeline.disabled`.
