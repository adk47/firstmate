# The stage-2 gap split: one class is admissible, the rest are held

The two `credit-stage2-gap-ask-*` crons have been `enabled: false` since 2026-10-27. This records
what the population actually is, which of it an approved message can reach today, and why the rest
cannot be reached without a copy decision.

Measured 2026-11-16 on node-8 against `/var/lib/hydra-credit-verify/proof.sqlite` (2.6 GB), with
`scripts/credit_review/stage2_gap.py counts`. Released = every role's latest `pf-2` verdict is
`need_more` and the account is not held.

## The population

**19,557 requests across 1,524 users (978 paying).** The brief's 5,327 / 400 is not this
population; it does not reproduce against the live store.

| gap class | requests | users | paid requests | route |
|---|---:|---:|---:|---|
| `track_not_named` | 14,809 | 1,175 | 8,216 | held |
| `unreadable` | 1,626 | 85 | 1,549 | **proof-need-ask (admissible)** |
| `covers_other_tracks` | 1,413 | 81 | 1,068 | held |
| `role_not_expressible` | 619 | 218 | 388 | held |
| `isrc_other_recording` | 417 | 49 | 339 | held |
| `cannot_confirm` | 380 | 81 | 165 | held |
| `mixed` | 164 | 65 | 77 | held |
| `unclassified` | 108 | 37 | 84 | held |
| `not_named` | 14 | 10 | 9 | held |
| `claim_text_not_rendered` | 7 | 5 | 4 | held |

**Admissible: 1,626 requests / 85 users** — the CLASS population, not what any sender reaches;
nothing is wired to list or send it (see the next section). **Held: 17,931 requests / 1,442 users.**
Per-class user counts overlap (a person can have requests in two classes), so they do not sum to
1,524.

`unclassified` is 108 requests whose `reason` is not `gap_reason` prose: rows written before #1297
carry the analyzer's own text. They are held, not guessed at.

## Nothing reaches this class today

`stage2_gap.py counts` is the class population, and this module records a routing decision that no
sender consumes yet. When a sender does consume these rows it will run its own gates first — a
`proof_intake` row naming the conversation for that document, the request still pending in core, the
never-ask bands, the stale-filing wait, the shared ask lock, one need per user — so the class
population is an upper bound and never a send count. Measured 2026-11-16 on node-8
by running `need_asks.build()` twice in one process: once with a stage-2 wiring experiment and once
with that experiment disabled (returning no stage-2 rows):

| count | with the stage-2 rows | without them | delta |
|---|---:|---:|---:|
| stage-2 unreadable rows | 1,626 | — | — |
| added to the outcomes | 1,572 | — | — |
| `skip_no_intake_row` | 15,326 | 13,756 | +1,570 |
| rows in the audience | 13,147 | 13,147 | **0** |
| users in the audience | 1,591 | 1,591 | **0** |

**So this class reaches 0 people today**, and no sender lists it. The measurement above is also why
this branch wires nothing: a class whose send gate holds it every time only adds backlog rows that
can never send.

Two prerequisites are missing, and neither is copy:

1. **A `proof_intake` row for the user's document**, so a sender knows which conversation to ask in.
   Only **32 of the class's 1,626 (user, proof_id) pairs** exist there for that user at all (33 by
   sha for any user), while all 1,626 exist in `proofs`.
2. **A doc-verify read of that same document, bound to that same intake**, recorded in
   `dv_outcomes` (`/var/lib/hydra-credit-verify/doc-verify.sqlite`) as `outcome="unverifiable"`
   with need `readable_document`. This is the gate itself: `comm_state.need_facts()`, reached for
   campaign `proof-need-ask`, reads `dv_outcomes` only — never `stage2_shadow` — and a request with
   no such row goes to `unchecked`, which sets `checked=False` and holds the message. 1,570 of the
   1,572 candidate keys are absent there.

`proof_intake` is filled by `credit-proof.py file-recent`, which walks recent conversations, while
these stage-2 rows go back to 2026-10-21. `credit-doc-verify-blob-backfill` is the (disabled) cron
that is the adjacent machinery for the read. The change that unblocks the class is that backfill
plus that read of those documents — not copy, and not another sender. The class cannot be reached
by any sender until both are built.

## Why the unreadable class is routed but not wired

The intent asked for this class to be wired into the existing document-ask path rather than given
new copy. Review round 2 raised that such a wiring would be held by the send gate on every row,
because `comm_state.need_facts()` requires a `dv_outcomes` row from
`/var/lib/hydra-credit-verify/doc-verify.sqlite` that is `unverifiable`, needs `readable_document`
and is bound to the named intake, and it never reads `stage2_shadow`. The measurement above confirms
it: the wiring added 1,572 candidate rows, 1,570 of them stopped at `skip_no_intake_row`, and only
32 of the class's 1,626 documents have any `proof_intake` row for that user. A wiring today would
produce backlog rows that can never send while the run counts looked like reach, so it was removed
rather than shipped inert. The routing table stays because it is the reviewed allowlist of which
class MAY be carried once both prerequisites exist; re-adding the wiring is a small change that
belongs with the pass that supplies them, where a test can assert a real send instead of a merge
into an audience.

## Why only one class

Two reviewer verdicts (Opus, tool-less, `policies/outbound-copy-rubric.md` verbatim; Fable was
rate-limited). The rubric admits exactly two messages that could carry this: the document ask, and
class 2.

**The document ask** is the right *kind* of message — nothing has been decided, the person sent a
document, we ask for one we can check. But its opening is fixed word for word: *"We have it on file,
but on its own it isn't something we can check against an outside source."* That is true only of a
file we could not read. For every other class stage 2 **did** check the document and found a
specific gap, so the sentence would be a false statement about the person's document. It is also
self-contradicting for a split-sheet sender: line a's first option is a split sheet, so the message
asks for what they already sent (rule 8).

**Class 2** was the reviewer's first answer for three of the classes, and the reviewer withdrew it:
class 2 is the message for a request that has been **decided**, and every row here is still pending.
`{title} was not verified` reads as a decided outcome and `Without it, the result stands` asserts a
result that does not exist, so the message would tell the person their request was decided when it
was not (rule 7). The rubric says it directly: *"A request for a document, sent before anything is
decided, is neither class."*

So `unreadable` is the one class where an admitted message is true, and it is the one class with a
route in the table.

## What the change does

- `scripts/credit_review/stage2_gap.py` — reads `gap_reason`'s prose back into a class code, and
  holds the routing table. The table is the allowlist: a class absent from it is held, so a new
  `gap_reason` branch cannot be sent by being forgotten. `test_stage2_gap.py` runs the real
  `gap_reason` for every branch and fails if one is not recovered.
- `scripts/credit_review/need_asks.py` — **untouched**, byte-identical to the base commit. Stage 2's
  rows cannot pass the send gate without both prerequisites above, so wiring them in would only
  produce backlog rows that can never send.

No copy was written. No cron was armed, no sender was wired, and the two `credit-stage2-gap-ask-*`
crons stay `enabled: false`: this branch arms nothing. The deliverable is the measured split, the
routing table the reviewer's ruling requires, and the two named prerequisites — not a send.

## What is still blocked

17,931 requests / 1,442 users need a document ask whose opening is true of a document that **was
read and does not cover the claim**. The rubric admits only the "we could not check it" opening, so
this needs a new admitted variant — a `policies/outbound-copy-rubric.md` edit, which voids every
verdict signed under the current rubric and holds every enforced campaign as `copy_review_pending`
until the reviewer host re-signs. That is a captain decision, not a merge.

The reviewer's own words on the smallest change: the document ask is the right home for a pending
request whose document cannot be checked; what it needs is an opening that says so truthfully.

## The amendment the reviewer would sign, in its own words

Asked what single admitted message it would approve for a **pending** request whose document was
**read** and does not cover the claim, the reviewer (`token-pool/claude-opus-5-5`, the gate's own
`FALLBACK_REVIEWER_MODEL`) wrote the amendment and the message below. It is recorded here, not
applied: `policies/outbound-copy-rubric.md` is untouched, because editing it voids every verdict
signed under the current rubric and holds every enforced campaign (`proof-refusal`,
`uvn-reminder-14`, `uvn-new-rows`) as `copy_review_pending` until the reviewer host re-signs. That
blast radius is a captain decision, not a merge.

### The amendment

> ## The read-document ask
>
> A fourth kind of message, neither class. Nothing is decided: we read the document, it does not
> confirm the credit, and we ask for one that does. It is admitted in these words only, and it
> loosens no other rule.
>
> Word for word, in order; braces are the only slots:
>
> 1. "Hi {first name}, thanks for {document} for your {role} credit on {title} by {artist}. We read
>    it, and it does not confirm that credit."
> 2. "To verify your credit on {title} as {role}, send one of these: a split sheet or agreement
>    signed by the artist or label, a PRO registration that lists you in your role, a royalty
>    statement that names the track, an invoice, or a letter from the label. Reply to this
>    conversation with it and we'll check it."
> 3. "Your request is still open."
> 4. "Thank you," then "Caroline, Muso Support".
>
> Slots, plural forms and subject are the document ask's. Part 1's second sentence says what the
> document shows. It is not which check failed (rule 2) and not a reason for a denial (rule 3).
> Anything added, including what the gap was, "not verified", "denied" or "the result stands": not
> approve. Every other hard rule applies unchanged.

### The message

```
Subject: About the document for your Muso credit request

Hi {first name}, thanks for {document} for your {role} credit on {title} by {artist}. We read it,
and it does not confirm that credit.

To verify your credit on {title} as {role}, send one of these: a split sheet or agreement signed by
the artist or label, a PRO registration that lists you in your role, a royalty statement that names
the track, an invoice, or a letter from the label. Reply to this conversation with it and we'll
check it.

Your request is still open.

Thank you,
Caroline, Muso Support
```

### Why it is true for a document we read

"We read it" is true, and it replaces the false claim that we could not check the document. "It
does not confirm that credit" holds for all five gaps without naming any of them, because each one
stops the document short of showing this person in this role on this recording — a missing name,
other tracks, a missing role, shares that do not add up, and another recording's ISRC all do this.
"Your request is still open" is today's state.

### What it still cannot say

It cannot say which gap was found, so a person whose split sheet does not add up may send the same
sheet again — that is the price of naming no gap and no ISRC. It cannot say the credit was not
verified, was denied, or that a result stands, and it carries no time, outcome or removal
statement. The reviewer judges only the text, so the truth of "We read it" depends on the sender
routing only read, pending requests to this message.

### What this would reach, if the captain admits it

The five classes the message is true for, from the measured split: `track_not_named` 14,809 req /
1,175 users, `covers_other_tracks` 1,413 / 81, `role_not_expressible` 619 / 218,
`isrc_other_recording` 417 / 49, `cannot_confirm` 380 / 81. `role_not_listed` (619 / 218) and
`shares_do_not_add_up` are the same shape and the reviewer's own list names them. `not_named`
(14 / 10) and `claim_text_not_rendered` (7 / 5) are small and would need their own reading.

**It would still reach nobody on the first tick**, and that is the honest number: the send gate
needs a `proof_intake` row and a bound `dv_outcomes` read for the document, and 1,570 of 1,572
candidate keys have neither. Admitting the copy removes the copy blocker; it does not remove the
data blocker. Both are named above.
