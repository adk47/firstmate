# Ops summarize / resolve (s1)

The Ops bot's `give me a summary and suggest a resolution <intercom link>` asks were **112 of the
301 asks Jan sent in 14 days** (37 %), and nearly every one is followed by
`do resolution then update the user`. Both used to be a free-form agent turn with root `exec`: the
summary was prose the model recalled, and the resolution was an LLM-chosen production write (7
profile renames, 3 association/card removals, 2 request statuses → UVN, 34 customer replies that
never touched the output guard, and ~39 refund/merge mentions).

This surface replaces both with code:

| | before | now |
|---|---|---|
| summary | model prose | `scripts/ops_intake/summarize.py` — a card built only from code reads |
| suggestion | model judgement | a **lookup** in `policies/ops-resolutions.json` |
| resolution | any write the agent chose | the mapped W1 action, or a hand-off |
| customer reply | free text to `/reply` | answer bank → output guard → `intercom-ops-write.sh` |

## The card

```
summarize · <ask_id> · account <hash> · facts: 2 open requests / uvn,unverified / 1 claim / 0 merges / erasure none / verify asks 1 proof on file dv none / sub active / 0 ClickUp tickets
intent: where_is_my_request · suggested: status-chase-open-request -> status-line · executed: none · sent: none · ledger none
customer «where is my request?»
```

`suggested` names **the policy key**, then the action. A wrong mapping is therefore a one-line PR
against `policies/ops-resolutions.json`, reviewable on its own, not an argument about a model.

### Facts are measured or they are `unknown` — there is no third state

Every fact carries `measured: bool` and a `source`, and `measured` is the authority on whether the
reader ran — `value is None` is not by itself "unmeasured". A reader that ran and found nothing
returns a real value — for erasure that is `{"status": "none"}` (a measured no-row), while `None`
means the register store is **missing on this host** and the fact is a measured UNKNOWN. An **unknown fact never satisfies a predicate**, so it falls
through to the hand-off instead of a write. This is the whole reason the module exists: `0 open
requests` and *could not read the requests* map to different actions, and rendering the second as
the first sends a promise about nothing. A missing erasure store is a staff line naming the host
and path (`erasure-store-missing`), never a customer ask to prove their erasure again.

Sources: Intercom conversation (`GET /conversations/{id}`), `identity_resolver` r5 for the account,
`credit_requests` / `claiming` / `subscriptions` on the Trino replica, the merge-verify audit store,
`erasure_requests`, `verify_messages` + `verify_proof_reviews`, and the ClickUp User Requests list.
Nothing on this surface writes to any of them.

### One customer quote, after the injection watch

Customer text is scanned with the Caroline injection watch **before** anything else happens. A HIGH
hit quarantines it: the card prints `customer text quarantined`, no model sees it, and the
resolution is forced to `unknown`. A clean quote is flattened, bounded to 600 characters and
delimited with `«»` so nobody can mistake customer words for ours.

### The intent label chooses nothing

At most one tool-less call (`credit_trust/llm.py`, codex on the subscription) produces a ≤ 40-word
label from a **closed enum** with `additionalProperties: false`. A failed call, an out-of-enum
label or a quarantined ask all yield `label=None` and a hand-off. A wrong label changes *which rule
fires*, never what code is allowed to do — the fact predicates and the action tiers are the
boundary.

## The resolution table

`policies/ops-resolutions.json` is the one table. Rules are tried in file order; the first whose
`intents` and `when` both hold wins; nothing matching is `unknown`. Load-time validation makes an
unknown action, intent, predicate, operator or answer-bank line a **`PolicyError`** — a rule that is
silently ignored is a rule that protects nobody.

Actions and tiers:

| action | tier | executes here | what happens |
|---|---|---|---|
| `status-line` | W1 | yes | one answer-bank line to the customer, through the output guard |
| `rename` | W1 | yes | `PUT` via the admin wrapper, inverse = the previous name; the name must be quoted by the requester as the whole remainder of the line, and the target must be exactly one profile owned by the resolved account |
| `gap-ask` / `uvn-status` | W1 | no | handed to the one sender that owns it (`credit-review.py`) |
| `merge-candidate` | human | no | `merge-verify.py` verdict + its command for a named human; never executed |
| `billing` | W2 | no | read-only subscription state + the approved refund line for a human |
| `erasure` | handoff | no | a GDPR register row (j-g1); **this surface never hides anything** |
| `erasure-store-missing` | handoff | no | the register could not be read: a staff line names the host and path; the customer is not asked again |
| `data-issue` | handoff | no | ClickUp categorization (j-k1) |
| `fraud-lens-ticket` | handoff | no | a fraud report becomes a lens ticket, **never a bulk status write** |
| `unknown` | handoff | no | the approved hand-off line, then a page naming the conversation |
| `requester-linked-refusal` | handoff | no | **no customer copy at all** + a page: the target account is the requester's own, so every write would be self-approval |

**Every action that does not execute here pages.** Nothing on this surface can reassign an Intercom
conversation — `router._production_writers()` is empty by captain decision, so no reassignment writer
exists. A hand-off that posts a line and pages nobody leaves the case with the bot while the customer
has been told someone will follow up, which is the exact failure the census found. `page` is therefore
required on every non-executing action, and `refuse` (which forbids customer copy) is the one flag that
overrides it. `scripts/check-ops-resolutions.sh` fails the build if a handoff action does neither, or if
a refusing action names an answer-bank line.

The `2026-10-23` "Mixed by Big Boy" case ("they are a fraudster, reject everything") maps to
`fraud-lens-ticket`; a rename/merge whose target is popular (`pop ≥ 60` or `≥ 50` credits) is W2
(an impersonation surface), measured on the named profile rather than the account; a requester who
names a profile the resolved account does not own is a refusal plus a page; a requester-linked
account is a refusal plus a page, because every write would be self-approval.

## The answerer executes nothing

`answer.answer_summarize_resolve` is wired into the router's `summarize-resolve` class, so the Ops
bot's Slack ask gets the card and the lookup. It **returns a `WriteRequest` and performs no write**.
The router's step 9 is the only executor, and it runs, in this order, none of it optional:

1. **tier** — `policy.may_write`; W2 / handoff / human actions are never executed here;
2. **fraud lens** — a hold, or a lens that cannot run, refuses;
3. **caps** — ≤ 20 W1 writes per requester per hour, ≤ 3 per target per day, counted from the same
   rows the writes land in;
4. **inverse** — `ledger.plan` writes the row **before** the write is attempted; no inverse means
   no write (that is what makes something W1 rather than W2);
5. **write** — through an injected writer. `router._production_writers()` returns `{}` by captain
   decision, so today a plan is recorded with its inverse and marked as not executed.

A second executor in the answerer would skip all five, which is why there is not one: the writers
are gated off deliberately, and a direct write would perform behind a gate a human closed.

The customer reply is the one thing the answerer does build: the answer-bank line → the real
`caroline-output-guard.ts` (via `guard_bridge.mjs`, no Python copy) → a `WriteRequest` for
`intercom_customer_reply`, whose writer is `scripts/intercom-ops-write.sh reply --customer-facing
--approved-by <requester>` (pinned identity, leak refusal, api-log before the POST).

A guard that cannot run raises `GuardUnavailable` and **nothing is proposed**. The request carries
the guard version, so "we sent it through the guard" is a claim with a value behind it.

### The intent label goes through the guard, not around it

The ≤ 40-word label is the one model call, and it is made through `guard.Guard.call` — the path
that wraps the customer text in a nonce and raises `CanaryLeak` when the model echoes the frame
back. A canary leak fails the whole ask closed and pages; it never degrades to `unknown`. Calling
the raw judge instead would leave that check silently dead (red-team case 07).

## Ledger

`${OPS_INTAKE_ACTIONS_DB:-/var/lib/hydra/ops-intake/actions.sqlite}` — the router's `action_ledger`
(j2), one row per decision, written by `ledger.ActionLedger.plan` **before** the write and carrying
the inverse. `plan` refuses a row with no inverse, a tier outside `W1`, or an inverse equal to the
action, so an undo never depends on reconstructing state afterwards. Only planned/applied rows
count against the caps.

## Running it

```bash
python3 scripts/ops_intake/summarize.py <conversation_id>            # the card, no writes
python3 scripts/ops_intake/summarize.py <conversation_id> --json      # the same, machine-readable
python3 scripts/ops_intake/summarize.py <conversation_id> --no-model  # never call a model
```

`summarize.py` never writes and never sends. In production the card is produced by the router's
`summarize-resolve` answerer, which is the same code path plus the write request.

`--json` redacts exactly what the card redacts: the account id, the contact's email and external id
are replaced by the same hash the card prints, and the customer text is emitted only when it is not
quarantined. A JSON view that printed the raw identity would be the same leak through a different
door, and `--json` output is what lands in a log, a ticket or a model prompt.

## SLA and escalation

Summary ≤ 5 min and resolution ≤ 15 min after "do resolution"; a breach is printed on the card.
Anything the card cannot resolve is a hand-off with the human path spelled out — the alternative
(an improvised write) is the failure this surface removes.

## Tests

- `tests/test_ops_intake_summarize.py` — the lookup: closed policy validation, "an unreadable fact
  never satisfies a predicate", erasure `none` still mapping to the erasure lane, quarantine,
  requester-linked refusal, popular rename, fraud report, card format, label vocabulary.
- `tests/test_ops_intake_summarize_resolve.py` — the answerer: a mapped W1 action becomes a
  `WriteRequest` and no writer is ever called, a hand-off tier still sends its approved line, a
  guard that cannot run or that blocks sends nothing, quarantine answers with a page, and a rename
  needs an unambiguously quoted requester-supplied name plus a measured previous name, exactly one
  named profile that the resolved account owns, and a popularity measured on that profile.
- `scripts/tests/ops-intake-guard.bats` — the cross-language contracts: the Python side runs the
  plugin's real guard, every policy line exists in the real answer bank, the Python guard bridge
  refuses a promise line and passes an approved bank line, and the reply path refuses a body that
  leaks internal surfaces.
- `scripts/check-ops-resolutions.sh` — CI: the lookup stays closed (no rule reaches a W2 action, no
  merge/erasure/refund executes here, every `executes_here` action is W1 with an inverse, the last
  rule is the `*` → `unknown` fallthrough).
