# Unmatched proof documents: identity-link proposals (2026-10-29 19:0xZ)

**Duty:** standing duty of intercom-backlog-i1 (Fable verify-program-lead-fable-l1). Read-only:
nothing was filed, linked, written to Intercom or core, or sent.

**Generator:** `scripts/intercom-backlog/intake_proposals.py`, read from node-8's
`/var/lib/hydra-credit-verify/intake-unresolved.jsonl`. The tray had 24 lines for 19 distinct
conversations. The rule is verified email only (see the script docstring).

**Count line:** intake-unresolved 2026-10-29: new 19 / linked 0 / still unresolved 19 (proposals 12, wait 2, no-proposal 5)

## The pattern for l1 to rule on

**11 of the 12 proposals are not identity problems.** The contact's external_id IS the account's
own presented profile, the id the mobile app logs into Intercom with (x2's r5 rule, already
applied by `intercom_reconcile.presented_owners`). The intake's identity check
(`credit_verify/proof/intake.py strict_identity` -> `professional_lookup`) only knows
`users.neptuneprofessionalid`, so it calls these "not a Muso account" and trays them.

- **Fix in the intake (the coded resolver), not in Intercom:** resolve the external_id with the
  same r5 presented-profile ownership `intercom_reconcile` uses, keeping the email-hash match.
  These 11 would then file on the next intake run, with nothing written to Intercom.
- **The 1 real A2** (an orphan external_id, verified email) goes to `credit-review.py intercom-reconcile`.

## Proposals (first 10 marked for l1's rule review)

| conversation | account | fix | paid | account age (d) | review |
|---|---|---|---|---|---|
| 215475720768704 | 211815 | R5 | - | 695 | l1-rule-review |
| 215476337154949 | 16471 | R5 | - | 1764 | l1-rule-review |
| 215476379885321 | 1405059 | R5 | - | 24 | l1-rule-review |
| 215476444399022 | 1407621 | A2 | - | 11 | l1-rule-review |
| 215476472196994 | 313462 | R5 | - | 377 | l1-rule-review |
| 215476595037075 | 1409108 | R5 | - | 3 | l1-rule-review |
| 215476603594494 | 38982 | R5 | - | 1441 | l1-rule-review |
| 215476605664499 | 136029 | R5 | paid | 976 | l1-rule-review |
| 215476606339737 | 136029 | R5 | paid | 976 | l1-rule-review |
| 215476608598432 | 185798 | R5 | paid | 790 | l1-rule-review |
| 215476610650305 | 1383747 | R5 | paid | 120 | - |
| 215476610655809 | 260128 | R5 | - | 587 | - |

## Not proposed

| conversation | decision | reason |
|---|---|---|
| 215475149515398 | no-proposal | the thread's contacts carry different emails |
| 215475969049168 | no-proposal | no Muso account has this email |
| 215476518892059 | no-proposal | no Muso account has this email |
| 215476603333796 | wait | the contact is younger than 24 h (the intake retries it) |
| 215476605789994 | no-proposal | no Muso account has this email |
| 215476608637040 | no-proposal | another account has a reverted claim on the contact's external_id (149309) |
| 215476612006669 | wait | the contact is younger than 24 h (the intake retries it) |

**Notes:**
- Conversation 215476605664499 and 215476606339737 are the same account (136029).
- 3 lead-only threads carry an email no Muso account has; they stay unresolved (never by name).
- The daily run is codified as the openclaw cron `intake-unresolved-proposals-daily` (07:20Z, read-only, delivery none). It starts with the deploy of this PR.
