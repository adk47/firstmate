# status-doc-received: where the selected rows go (2026-11-15)

Captain's question: the tick selects `status-doc-received`, logs `100 of 100 left this tick`, and
sends nothing. Find the drop between selection and the send call, fix it, prove it with a test.

## Answer

1. **The rows are discarded at `scripts/intercom-verify-request.sh:3333`**, the `exit 3` behind
   `HELD r1_receipted_in_thread`. The predicate is `RECEIPTED_JQ` (line 1566, called at line 3330):
   a worded comment of ours in the filing conversation after the customer's latest attachment.
   The tick runs every person through that gate in its dry-run check, the check accepts nobody
   (`scripts/credit-verify-outbound.sh:889`, exit 3), and the family ends at
   `scripts/credit-verify-outbound.sh:1214` (`the check accepted nobody; no apply this tick`).
   The copy gate, the route and the apply are never reached.
2. **That hold is a ruling doing its job, not a defect, so no code is changed here.** It shipped on
   2026-10-30 in #1554 (`f7e7108a1`, "r5 HOLD - R1 skips a filing thread we already acknowledged in
   free text") and six bats assertions pin it (`scripts/tests/intercom-verify-request.bats:4696-4708`,
   `4811`, `5286`). I read all 641 held threads with a tool: in 389 our comment after the document is
   Caroline's approved `document_thanks` line
   (`plugins/intercom/src/answer-bank.ts`, "Thank you. Everything you send here is recorded against
   your account and your open requests and goes to the verification team."), posted 22 to 41
   seconds after the upload in the 10 threads of a 30-thread sample where the upload has its own
   timestamp; in 150 more our first comment carries a document noun (a text match, not read by a
   person); I read the other 102 first comments myself and 52 of them are about the document. A
   receipt from this family would tell the same person the same thing a second time in the same
   thread.
3. **Nothing broke on 2026-11-05.** The family has sent 4 messages from the tick in its whole life
   (2, 1 and 1 on 11-03, 11-04 and 11-05). The other 842 went out in hand-run batches on 10-22 to
   10-29, before the hold existed. `868 rows` is 846 sent plus 22 rejected.
4. **I wrote no test.** A test that "fails on the current code and passes after the fix" would have
   to assert that a receipt goes into a thread Caroline already answered, which is the behaviour
   the ruling forbids and the existing tests assert against.

What this means for a customer: a person who uploads a document in chat is told within a minute
that it was recorded and went to the verification team. Nobody is waiting on this family for that
sentence.

## Per stage, tick `20261115T1100Z` (node-8, deployed `dfb37e7db`)

The four files below are byte-identical between the deployed sha and this branch's base
(`git diff --stat dfb37e7db..babea62ec` is empty for them), so the line numbers hold on node-8.

| stage | what the tick recorded | drops here |
|---|---|---|
| selection (`receipts.py build`) | `list_received_paid 789`, `list_received_free 939` | 0 |
| arming | `arming=policy ... r1=live/paid from 2026-11-03T12:56Z` | 0 |
| budget (`credit-verify-outbound.sh:1146`) | `100 of 100 left this tick ... cap 100` | 0 |
| dry-run check through the send gate | `789 on the list, 0 would be messaged`; `accepted: []` | all |
| copy gate, route, apply | not reached (`credit-verify-outbound.sh:1214` returns first) | - |

## Per gate, the whole list

Latest outcome per listed user over the 58 r1 checks of the last two days (0 accepted in all 58).
Tool: `tools/measure.py gates`.

| | filed before 2026-10 | filed 2026-10 | filed 2026-11 | all |
|---|---|---|---|---|
| on the list | 685 | 415 | 628 | 1,728 |
| `r1_receipted_in_thread` | 75 | 231 | 302 | 608 |
| no gate call: the runner's own holds (already receipted, 7-day cooldown, fraud lens) | 466 | 84 | 176 | 726 |
| `core_notice_within_7d` | 39 | 34 | 104 | 177 |
| `r1_unreadable_filing` | 25 | 34 | 25 | 84 |
| `r1_filing_class_unknown` | 57 | 15 | 7 | 79 |
| filing is a Muso screenshot | 11 | 10 | 8 | 29 |
| identity (G2/G3/G5), `comm_state`, `no_channel`, `gate_timeout`, other | 12 | 7 | 6 | 25 |
| **accepted** | **0** | **0** | **0** | **0** |

Of the people the gate was asked about, `r1_receipted_in_thread` is 608 of 1,002. The rest are
rules already described in `data/send-families-zero-sends-r1/report.md` (11-13): a 7-day pause
after core's own notice, a filing doc-verify has not read, a filing with no text, a screenshot of
Muso.

## What we said in the 641 held threads

641 listed users had a `r1_receipted_in_thread` outcome in the window. One read of each filing
conversation, the gate's own predicate rebuilt in Python, 0 read failures (`tools/measure.py
threads`). The first two classes are a text match, not a person's reading.

| our comment after the document | before 2026-10 | 2026-10 | 2026-11 | all |
|---|---|---|---|---|
| the answer bank's `document_thanks` line | 0 | 96 | 293 | 389 |
| first comment carries a document noun (document, attachment, screenshot, invoice, file) | 38 | 101 | 11 | 150 |
| first comment carries no document noun: read one by one | 46 | 45 | 11 | 102 |
| | 84 | 242 | 315 | 641 |

The first comment after the filing was written by Caroline's account in 615 threads, by another
admin in 22 and by the Intercom operator bot in 4.

I read the 102 first comments with no document noun myself. 52 are about what the customer sent:
they acknowledge it in Spanish, Portuguese, French, Italian or Thai, or in words with no document
noun ("Got this too. Thank you!", "I've received the agreement and passed it to our team"). The
other 50 are not: 30 are our answer on another subject, 8 ask for a profile link or a detail
without mentioning what was sent, 8 are the teammate hand-off line alone, 2 are an agent error
line, 1 is the operator bot's contact prompt and 1 is a holding line. So 50 of 641 people (8%) are
held on a first comment I read and found says nothing about their document. That is a count of
what was read, not a ceiling: the 150 comments in the second row were matched on a noun and not
read, and a comment can name a document without acknowledging one. The bats case at line 4706 ("a
human teammate's comment counts the same (any admin)") shows the ruling meant any worded comment,
so those 50 are inside the rule as written.

**This gap is escalated, not settled.** I raised it to firstmate (status keys `r1-hold-is-ruling`
and `qa-nogo-acceptance-2031`). Firstmate's decisions record it as a disclosed gap escalated to the
captain, because clearing it means narrowing the hold, and that reverses a recorded reviewer ruling
on customer copy. Nothing in this change acts on it: `RECEIPTED_JQ` and the bats case at line 4706
are untouched, and those 50 people are still held.

An earlier version of this report said 188 comments named the document and at most 34 did not. Its
pattern matched `file` inside "profile" and counted verbs such as "review" and "forward" as naming
a document; review of this change caught it, and the table above is the re-measured one.

## One mismatch that exists and drops nobody

`receipts.py:162` takes `filing_conversation` from a user's earliest filing, while the note's
request ids are the union of every filing. The gate therefore reads the first thread even when the
document for a still-owed request arrived in a later one. 81 of the 641 held users are in that
position. In all 81 the later thread carries our comment after its filing too, so reading the
right thread would hold the same 81 people.

## What would make this family send

Only narrowing or removing the hold at line 3333. That sends a second acknowledgement to people
Caroline already thanked, and it reverses a recorded reviewer ruling on customer copy. It is not a
repair, and it is not mine to decide.

The 11-13 report already recorded the part that is untidy: the hold writes nothing to the ledger,
and `receipts.py build()` does not read the verify ledger, so the same 1,728 people are listed and
re-checked every tick and the log reads as a family with work it cannot do. Fixing that changes
what the tick prints and saves about 600 Intercom reads per rotation. It sends no message. It is
not fixed here: firstmate's decisions name it as a separate task,
`status-doc-received-list-hygiene-r1`.

## Decision on record

Firstmate, 2026-11-15T12:15Z, status key `r1-hold-is-ruling`: (a) close as working-as-ruled. The
evidence is accepted, there is no defect, a test that fails and then passes would assert against a
recorded reviewer ruling on customer copy, and the hold is not narrowed or removed here because
that is a captain call. The decision was made on the first classification (577 about the document,
at most 34 not); the corrected read above (389 + 150 by text match, 52 of 102 read, 50 not) was
made after it and changes neither the line where rows are discarded nor the 0 accepted in 58
checks.

Firstmate, 2026-11-15T14:29Z, status key `qa-nogo-acceptance-2031`: the acceptance criterion is
revised to evidence-only. The original one (a fix, and a test that fails on the current code and
passes after) was written on the assumption that a defect existed; there is none, so the criterion
was wrong and the evidence is the deliverable. The revised criterion is that this report:

- names the line where the row is discarded (`scripts/intercom-verify-request.sh:3333`) and the
  predicate that fires it (`RECEIPTED_JQ`, line 1566);
- gives the measured population (0 accepted in 58 checks over two days; 608 of the 1,002 people the
  gate was asked about held there; what our comment says in the 641 held threads);
- says plainly that no code changed and why;
- discloses the people held on a comment that is not about their document, marks that escalated to
  the captain, and names `status-doc-received-list-hygiene-r1` as the separate task.

No code change is required for it to pass. That decision quotes the first classification (577 of
641, at most 34); the figures that stand are the corrected ones above (389 on the fixed line, 150
more by a noun match nobody read, 52 of the 102 read, and 50 not about the document).

## Reproduce

All reads, nothing written on node-8, no body or name printed:

```
ssh root@<node-8> 'python3 - gates'   < data/status-doc-received-drop-r1/tools/measure.py
ssh root@<node-8> 'python3 - ledger'  < data/status-doc-received-drop-r1/tools/measure.py
ssh root@<node-8> 'python3 - threads' < data/status-doc-received-drop-r1/tools/measure.py
```

`threads` makes one Intercom GET per held user (about five minutes).
