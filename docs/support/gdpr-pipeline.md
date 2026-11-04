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
| identity | per page, from the core replica (claims, users), the admin catalog (name, claimed, popularity, credits, website) and the Intercom contact (identity_resolver r5 on `external_id`; the account email only when the address was delivered by mail or is an identified user): A claim · B account whose name matches · C unclaimed + name-fold match (sender name or email local part; at least two name tokens) **only for a VERIFIED sender — a ticket's requester-typed email is metadata, not proof, so an unverified ticket goes to ASK** unless popularity >= 60 or >= 50 credits (Jan) · D sender domain = the page's own website domain in our catalog (no freemail) · E representative -> ASK for authorisation · legal_threat -> hide first (captain) unless big-name · DMCA stays claim-first. An 8-char prefix is resolved ONLY against the catalog (`resolve_prefixes`): a full id that happens to be in our rows/hide lists does not prove the prefix is unique, so an ambiguous prefix stays UNKNOWN and its pages are never attributed by guess | `gdpr_pipeline/identity.py`, `sources.resolve_prefixes` |
| hide | `hide-batch` plans identity-PASS profile pages, most overdue first, skips ids already in an open PR, and opens ONE H-DevOps PR (`HIDDEN_ENTITY_IDS`, prod + dev: 410 + noindex) and ONE platform-data-processing PR (`LEGAL_HIDDEN_ENTITY_IDS` + the strict-equality test's `ERASURE_PROFILES`, ref `gdpr-erasure-register-<n>`). A person merges. Only the anonymous 410 + noindex read-back (`mark-hidden`, every tick) sets `hidden_at`, per ELIGIBLE page (`hidden_pages`): a row that carries a PASS page next to an ASK / Jan page records its hide as soon as the PASS page is down, while a letter still waits for the whole row | `gdpr_pipeline/hide_batch.py`, `checks.public_gone` |
| confirm | for rows due within 3 d (or hidden): the approved letter (`erasure-confirmation-template.md`), lines S/P/M only from THIS run's checks (S: public autocomplete exact/lower/prefix; a FULL results page without the id is "cannot verify here" → `Unknown`, never "absent" — the endpoint has no paging, so a name with more matches than its cap can hide the target; P: 410 + noindex on /profile and /credits; M: every sitemap file walked, one unreadable file = no M line), `[D-no]` always, G never | `gdpr_pipeline/copy.py`, `checks.py` |
| asks | the approved lines only, verbatim: link line (no page), v2 step 1 (identity), authorisation line (representative). A row ALREADY past its statutory date carries the past-due opening line first ("the deletion request you made on {date} is in progress ...") because the ruling requires the letter to acknowledge the delay instead of reading as a fresh promise — and while `copy.PROGRESS_LINE_APPROVED` is False a past-due ask is **REFUSED** (ledgered, retryable), never sent missing that sentence and never sent with wording nobody reviewed | `copy.ASK`, `copy.progress_line` |
| **send** | ONE ledgered letter per request through the approved writers: `intercom-ops-write.sh reply --customer-facing --approved-by <human>` for a conversation, `gog gmail send --thread-id … --reply-all` from `support@muso.ai` for a support@ thread. The body is the approved copy byte for byte; `erasure_sends` holds `body_sha` + the writer's receipt, `UNIQUE(request_id, kind)` is the double-send guard, and the row is written `sending` BEFORE the writer runs | `gdpr_pipeline/send.py`, `erasure_sends` |
| watchdog | hourly tick pages #cs_priority (Jan) every open request at or past `due_at - 3 d` without `confirmed_at`, and identity ASKs unanswered > 7 d. The page fires per REQUEST, not per day-count: it is suppressed only for register numbers already paged today, so a request that becomes due the hour another one is confirmed is still paged. Each line carries the SEND FACT as well as the date (`no letter sent`, `no letter sent, N d past the deadline`, `letter failed`, `letter sent <date>`): "overdue" and "a letter went out" are two different claims, and on 2026-11-03 the line made only the first while 97 decided requests had no letter at all. When a row has no route at all, or the pipeline TRIED and the writer refused, the line names that and its reason (`no route for a letter (…thread is in a mailbox gog cannot write…)` / `the ask letter is refused (…)`): on 2026-11-04, 24 of the 141 approved letters were unroutable, and without the reason they read exactly like a broken pipeline instead of a missing mailbox auth. The route check is a pure capability test (`send.route`), so it names the blocker before anything has been attempted — the ledger only knows about attempts that happened | `run.watchdog_rows`, `erasure_sends` |
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
  `GDPR_APPROVER_SEAT` when set, never a name we were given);
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
  `(register, row, sha256(body))` about to leave, so one changed letter, row or order invalidates it, and the approval
  is valid for `TTL_HOURS` (2 h). The dry run prints the **digest only** — never an accept string, because a pipeline
  that prints what the gate accepts manufactures its own approvals.
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
- **A confirmation has TWO letters and they get two slots.** An interim letter goes out while the pages are not yet
  off the public view ("the remaining step is in progress"); the final one says they no longer show the information.
  The interim is ledgered in `confirm-interim` and sets `interim_confirm_at`; only the final uses the `confirm` slot
  and sets `confirmed_at`, which is what takes the row out of the confirmation queue. With one slot the interim
  consumed it and the closing letter could never send. The deadline alert names which one happened — "interim letter
  sent …, final letter NOT sent" — because "no letter sent" while one is with the customer is the wrong fact.
  - **Every route fails closed.** A `legal@` / `notices@` thread is REFUSED, not skipped: those mailboxes are not
    authed in gog on node-8, so the letter cannot be threaded there and the ledger records `refused` with that
    reason. Same for a non-numeric conversation id or a row with neither a conversation nor a thread: the pipeline
    never opens a new thread with copy nobody approved.
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

## Commands

```
gdpr-pipeline.py backfill --register removal-erasure-register.md --out backfill.md   # once
gdpr-pipeline.py tick --page                 # hourly (gdpr-pipeline-tick.timer, install-aux-units.sh)
gdpr-pipeline.py hide-batch                  # dry run: prints both diffs
gdpr-pipeline.py hide-batch --open-prs       # opens the two PRs (records them on the rows)
gdpr-pipeline.py confirm --sitemap           # renders the letters due within 3 d with verified lines
gdpr-pipeline.py ask                         # renders the identity asks
gdpr-pipeline.py report --out register.md    # the register table
gdpr-pipeline.py dedupe                      # report post-confirmation rows that are one customer event
gdpr-pipeline.py dedupe --apply               # close the duplicate, keys re-pointed at the row kept
gdpr-pipeline.py intake --candidate -         # record ONE request pushed by another producer (see below)
```

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

**One batch pair at a time.** `hide-batch --open-prs` refuses to open a second pair while one of its own
(`gdpr-pipeline/hide-*` branches) is still unmerged in that repository, and says which PR it is waiting for: both PRs
of a batch insert at the same point in the same list file, so a second pair can only conflict against ids nobody has
reviewed yet. The waiting ids stay un-hidden and every tick retries them; a hand-written hide PR (a different branch)
never blocks the batch. Only the half that actually opened is recorded on the row.

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
