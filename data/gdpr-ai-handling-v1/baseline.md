# GDPR / DSAR handling: measured baseline

Measured 2026-11-12 on node-8, read-only. Register counts are one snapshot at 00:47:38Z; the assignee pass
ran at about 00:40Z and the identity-gate pass finished at about 01:00Z. Sources: the erasure register
(`/var/lib/hydra-gdpr/erasure.sqlite`, opened `mode=ro`), Intercom (GET only), the core replica (Trino
SELECT), the admin catalog (GET, 35 reads). Counts only; no customer data left the box.

The queue is not small. 281 requests arrived in the last 30 days and weekly intake rose from 8 to about
60 over eleven weeks. This is a system problem, not a workflow tweak.

## 1. Arrivals, last 30 days

| Channel | Requests |
|---|---|
| Intercom | 194 |
| support@ mail | 59 |
| notices@ mail | 19 |
| legal@ mail | 6 |
| register (hand-entered) | 3 |
| **Total** | **281** |

There is no web-form channel in the register, so web-form arrivals are unmeasured, not zero.

By class: privacy_erasure 177, legal_threat 55, dmca_takedown 25, privacy_access (Art. 15) 15,
cancel-intent mentioning deletion 9.

## 2. What happened to them

Of the 281: 249 open and unconfirmed, 28 confirmed, 3 duplicates, 1 closed. 102 were sent an ask. 145
have no sent letter of any kind in the send ledger.

**Assignee distribution** (the 196 last-30-day requests that have an Intercom conversation; the register
keeps no assignee, so this was read from Intercom):

| Assignee | Conversations | Open | Closed | Got a pipeline message |
|---|---|---|---|---|
| Caroline (bot seat) | 170 | 159 | 11 | 94 |
| Jan Delmo | 26 | 4 | 22 | 0 |

The other 83 requests have no Intercom conversation, so no assignee at all.

So Intercom assignment to Jan is 13% of conversations, not the bulk. The human loop is elsewhere:

- Every due-date and review page mentions Jan in #cs_priority (`scripts/gdpr_pipeline/run.py:13-14`,
  `scripts/legal-intake.py:48-49`).
- The verdicts `JAN_REVIEW`, `JAN_BIGNAME` and `GONE` park a request for Jan: 131 open rows, 76 of them
  statutory.
- Every send requires `--approved-by` from a three-person list (`scripts/gdpr-pipeline.py:410`).
- Art. 15 access requests are routed to "captain/counsel": 28 open, 0 answered.
- The 22 conversations Jan closed carry no pipeline message, so nothing records what the requester was told.

## 3. The statutory clock

Art. 12(3): "without undue delay and in any event within one month of receipt of the request", extendable
"by two further months where necessary", with the data subject informed of the extension "within one month
of receipt".

Open and unconfirmed, all time: 450. Statutory classes (erasure + access): 309.

| | All classes | Statutory |
|---|---|---|
| Past due | 201 | 149 |
| Due within 7 days | 56 | 41 |
| Later | 193 | 119 |

- Oldest open statutory request: register #468, received 2024-01-04, due 2024-02-03, 1,012 days past.
  The next oldest is #327, 190 days past.
- Art. 15 access: 28 open, 13 past due, 7 due within 7 days, none answered.
- The register has no extension field and no extension event, so no row has more than one month.
- The register computes `due_at` as receipt + 30 days. That is later than one calendar month for a request
  received at the end of January, so it is not always the conservative reading.

## 4. Existing automation

There is a real pipeline (`scripts/gdpr-pipeline.py`, hourly tick, sending since 2026-11-06): intake from
Intercom, ClickUp and the mail ledger, a coded identity decision, reversible hide PRs, and two letters
(an ask, a confirmation). 178 letters sent to date: 138 asks, 40 confirmations.

What it lacks against the required process:

- **No acknowledgement.** The first message a requester gets is an ask or a confirmation, if anything.
- **No status update.** Nothing is sent between the ask and the confirmation.
- **No deadline stated** to the requester in any message.
- **No state machine.** A row is `open` or `closed`; one row of 489 is closed.
- **No AI authoring, no Fable gate.** Copy is fixed text approved by a named person.
- **The alarm pages a person** (Jan), three days out.

## 5. Identity gates (Aaron's ruling, 2026-11-12)

Ruling: account control, then a tie to the profile, then an authority document only where there is real
doubt. A passport is not asked for by default (Art. 12(6): additional information only "where the
controller has reasonable doubts concerning the identity").

How many of the 450 open requests pass each gate today:

| Gate | All open (450) | Statutory (309) | Erasure (281) | Access (28) |
|---|---|---|---|---|
| 1. Account control | 161 | 109 | 86 | 23 |
| &nbsp;&nbsp;signed in | 137 | 91 | 68 | 23 |
| &nbsp;&nbsp;controls the account email | 24 | 18 | 18 | 0 |
| 2. Profile tie | 40 | 33 | 24 | 9 |
| &nbsp;&nbsp;claimed by the requesting account | 39 | 32 | 23 | 9 |
| &nbsp;&nbsp;own website matches the sender | 1 | 1 | 1 | 0 |
| &nbsp;&nbsp;own DSP URL or social handle | unmeasured | unmeasured | unmeasured | unmeasured |
| 3. Authority document on file | unmeasured | unmeasured | unmeasured | unmeasured |
| **Gates 1 and 2 both pass** | **40** | **33** | **24** | **9** |

Why the rest do not pass:

- 289 do not pass gate 1. For 91 of them the sender's address is unverified. Separately, 131 of the 450
  have no sender on file at all (mail rows whose thread was never read back). The two groups overlap.
- 121 pass gate 1 but not gate 2. These are the "claim the profile, or send evidence of authority" group.
  59 of them have not named a profile yet.
- 196 requests name no page; 15 name a profile claimed by a different account.
- 4 are written on someone else's behalf and need an authority document.

Gate 2's DSP-URL and social-handle checks and gate 3 are unmeasured because no check or store exists for
them yet. That is not the same as zero.

Under the current rules a name match alone (paths B and C) can pass a request. Under the ruling it cannot.

## Method notes

- The store writes `''` for an unset timestamp, never NULL. A `confirmed_at IS NULL` filter matches no
  rows; use `COALESCE(confirmed_at,'') = ''`.
- Gate 1 reuses the pipeline's own resolver (`sources.resolve_account`); gate 2a its claim reader
  (`sources.processed_claims`), requiring every named profile to be claimed by the requesting account.
- "Past due" is against the register's own `due_at` as of 2026-11-12T00:47:38Z.
