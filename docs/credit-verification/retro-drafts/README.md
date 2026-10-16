# credit-retro request-for-information templates

These are the templates the prepared waves name in their `template` field
(`scripts/credit_retro/waves.py`). Nothing in this repo sends them. Sends go
through `scripts/intercom-verify-request.sh` (credit-trust-caroline-t06), rate-limited,
once that tool can render these templates and firstmate gives a GO.

The copy follows captain 2026-10-16 ~00:35Z (firstmate 005): "how many credits were
approved without documentstion i dont want to lose users unless its obvious fraud feom
tbe past".

**PAST credits.** Only GENUINE risk is asked (firstmate 006, captain ~02:00Z: "are you
annoying people fornbackup that we shpuldnt be?"). That means:
- Part A / Part C HOLD;
- the velocity and editing-burst accounts, one ask each;
- contradicted editing claims and unverifiable editing claims on mid/big tracks.

Everyone else is not asked and is flagged internally only. For those who are asked:
- The ask is friendly, with no removal threat and no deadline language.
- A valid document raises trust.
- If the user is silent, the credit stays on the profile, flagged unverified internally.

| File | Review state | Used by |
|---|---|---|
| `retro-verify-grouped.md` | **NEW DRAFT, not reviewed.** One message per user listing all their credits, grouped by role | waves W-01..W-nn |
| `account-three-tracks.md` | **NEW DRAFT, not reviewed.** ONE ask per velocity or editing-burst account: three tracks of their choice. A user with HOLD rows too gets one grouped message that carries this as a section (payload `account_asks[]`) | `account_asks` |
| `retro-follow-up.md` | **NEW DRAFT, not reviewed.** One optional friendly nudge at day 14, with no deadline | `follow_up_on` |
| `takeback-mixing-mastering.md` | **NEW DRAFT, not reviewed.** Sent only to users whose proven-fraud role was removed (trusted public credits name someone else) | wave T-01 |

**Older Fable-GO copy, kept verbatim.**

| File | Status |
|---|---|
| `hold-mixing-mastering.md`, `hold-writer-composer.md`, `hold-producer.md`, `hold-engineer-assistant.md`, `hold-musician.md` | Fable copy GO 2026-10-15 ~21:45Z, verbatim from the f1 retro review. These are single-credit versions. Their "within 14 days ... nothing is removed" wording fits the past-credit rule, but the window sentence needs to go |
| `reply-proof-received.md` | Fable copy GO, verbatim |
| `reply-no-proof-14d.md` | Fable copy GO, verbatim. Superseded by `retro-follow-up.md` |

These rules come from the Fable review and apply to every file here:
- The copy is plain, kind and specific. It never says "fraud".
- It never uses em dashes.
- It never promises an outcome.
- It only says what is true on the send date.

No draft here carries a removal date: nothing these waves ask about is removed for silence.

Placeholders:
- `{first_name}`, `{grouped_credit_sections}` (from payload `groups[]`) and
  `{more_credits_line}` (used when `more_credits` > 0).
- `{reason_line}` is chosen by the server from `reason_line`.
- `{sent_date}`, `{credits_count}` and `{first_track_title}` are used by the follow-ups.
