# The outbound copy gate

Captain, 2026-11-12: *"make sure you're communicating properly with the users and check your messages with Fable.
Make sure Fable likes the messages that you're sending out. ... let them know if something was denied. You don't have
to tell them why. ... If there's fraud, you don't tell them there's fraud. You just say for now the credit's denied.
You can always resubmit for a credit again later."*

**The rule:** every customer message is reviewed by the reviewer (Fable) on its exact bytes, and the review is a signed
statement anyone can re-check, not a log line. In **enforce** mode a message leaves only with an approval. In
**observe** mode it leaves while the review is recorded. A refusal, a code-lint hit and a retired copy never leave, in
either mode.

## Observe first, enforce one campaign at a time

The first measurement over the 77 distinct bodies the verify sender's own suite renders had the reviewer approve 20
(2026-11-12). Enforcing everywhere on the day it lands would stop most customer messages, and a gate that stops
everything is a gate somebody switches off. So the mode is per campaign, in `policies/outbound-copy-enforce.json`:

| | observe (the default) | enforce |
|---|---|---|
| no verdict yet | **sent**, and queued for review | held (`copy_review_pending`) |
| reviewer said `rewrite` | **sent**, recorded as copy backlog | held |
| reviewer said `approve` | sent | sent |
| reviewer said `refuse` | **held** | held |
| the code lint trips | **held** | held |
| the frame is `retired` in the table | **held** | held |
| the gate or its table cannot be read | **held** | held |

- An observed send is exit **4** with `result: observed`, `mode: observe` and `review: <pending|rewrite|...>`. The
  callers send on it only when it names the bytes they hold; a caller that does not know exit 4 holds.
- The ledger row says which it was: `copy_review` is `approved` (and names the verdict) or `observed:<state>`.
- The mode is the gate's table. No caller, flag or environment variable can ask for it, and a table that is
  missing or malformed is a gate that cannot run: everything holds.
- A campaign with its own rubric family (the GDPR notices) is always enforced, whatever the table says.
- `retired` rows name a campaign + copy that never sends again, whatever its words.

**The copy backlog** is `gate.py report --store /var/lib/hydra/outbound-copy`: per campaign, how many distinct bodies
are approved, need a rewrite, were refused or are still waiting, and `ready_to_enforce` when a campaign has approvals
and nothing else. `--notes <campaign>` prints the reviewer's note and proposed text for each non-approval: that is the
rewrite work list. **Moving a campaign to enforce is a one-line PR** that adds it to `enforce`, says why in
`_enforce_why`, and cites that report. One campaign at a time.

Shipped table: `decline` is enforced (the reviewer approved all 4 rendered denial bodies, and `DECLINE_CORE_ROUTE_OFF=0`
means it carries no live traffic); `uvn-reminder-14` is enforced (new copy with no standing approval, so there was no
`report` to cite; the sender also holds an `observed` pass as a belt, see `verify-request-notes.md` day-14 reminder);
`uvn-new-rows` is enforced (its sender lock waited on a human sign-off of the first dry run; the reviewer approved all 6
bodies of that dry run on 2026-11-14 and that verdict replaced the sign-off, so the lock is open and the sender holds an
`observed` pass for it as it does for the reminder);
`credit-approved-elsewhere` is enforced from its first byte (no reviewer has read the
line, and the sender locks it with `APPROVED_ELSEWHERE_COPY_APPROVED=0`, so enforcing it stops no message that is sent
today); `verify-live` / `windowed` is retired (it states a removal deadline; the reviewer
refused it, and the sender already locks it with `LIVE_WINDOWED_COPY_APPROVED=0`); everything else is observed.

## How it works

| step | where | what |
|---|---|---|
| 1. ask | the sender (node-8) | `scripts/outbound_copy/gate.py check` hashes the body it is about to POST and looks for a verdict on that hash |
| 2. queue | the sender | no verdict: the body is written to `/var/lib/hydra/outbound-copy/pending/`; an enforced campaign **sends nothing** (exit 3), an observed one sends and says so (exit 4) |
| 3. review | the reviewer host | `scripts/outbound_copy/review_pull.py` fetches the held bodies, asks Fable against `policies/outbound-copy-rubric.md`, signs each verdict |
| 4. store | the sender | `gate.py import-verdicts` keeps only statements signed by the key pinned in `policies/outbound-copy-reviewer.allowed_signers` |
| 5. send | the sender | the next run finds an `approve` on the same bytes and sends; the ledger row carries `copy_verdict_id` + `copy_verdict_sha256` |

The sender can **verify** a verdict and cannot **mint** one: the signing key is not on node-8, and node-8 has no route
to the reviewer model. A verdict is bound to `body_sha256`, `subject_sha256`, the campaign, the frame the body is sent
in (`copy`), the stage, the rubric's name and the rubric's sha256. Change one byte of the message or one byte of the
rubric and the old approval is void.

**Every visible byte is copy.** The lint and the reviewer read everything a person would see: text in any element
(a list item included), bare text, and the attribute values a reader sees or hears (`alt`, `title`, `placeholder`,
`aria-label`, a form `value`), quoted or bare, on any tag, one inside a list item included. A sentence in a `<div>`
or an `<li>` beside an approved `<p>` is read and linted like any other.

**Markup excuses nothing; declared request data does.** A song can be called "Fraud" by an artist called "Because".
The sender declares the request's own values with the body (`data`: the first name, each credit's role, title and
artist), and the lint blanks exactly those values, as whole words, as many times as they were declared, before it
looks for accusation and reason words. One track called "fraud" excuses one "fraud"; the same word in our own
sentence beside it is still a hit. The reviewer is shown the whole text and the declared values. A sender that
declares nothing gets no excuse, so a title that trips the lint is held for a person rather than waved through.

**The frame is part of the verdict.** A status line approved as a whole Intercom message (`intercom`) is not approved
as the line send-gateway places into an email template (`email-template:<key>@<sha256>`), and a line approved for
one template is not approved for another.

**An email template is pinned by the hash of its reviewed source.** The template's own words (subject, greeting,
footer) live in send-gateway, outside this repo, so the gate cannot read them. The policy records the sha256 of the
template source that was reviewed (`channels.email.template_sha256.<key>` in `policies/request-status-lines.json`),
and that hash is part of the frame. A template with no pin sends no email (`email_template_unpinned`, and the policy
validator refuses to enable the rung without one); a template whose words change needs a new pin, which is a new
frame no earlier verdict covers.

**The pin is checked against the live template at send time.** The script that posts to send-gateway runs inside the
gateway pod (`SEND_JS` in `scripts/request_comms/channels.py`). Before its one POST it hashes the template the pod
would render for the key (subject, preview text, html source, text source, from the image's `templates/` directory)
and posts only when that is the pinned hash. A template edited and deployed in send-gateway without a new review
therefore sends nothing (`template_pin_mismatch`, with the live hash in the answer), as does a template it cannot
read. The hash and the POST are one exec in one pod, so the template that was hashed is the one that pod renders.
Compute a pin from the reviewed checkout with `template_source_sha256(<templates-dir>, <key>)` in the same file; a
test runs the Python and the in-pod JavaScript against the same files and requires the same answer.

Limits that remain: the hash covers the template's source, not the gateway's rendering code, so words the gateway's
code adds (it appends an unsubscribe footer to non-transactional classes) are outside it; and no email has been sent
this way yet, because the email rung is off in the shipped policy and has no template keys.

What sends nothing **in an enforced campaign**, each with its reason recorded (`events.jsonl` in the store; a
`deferred` ledger row whose reason starts `copy_review_hold:` for the verify sender). The lines marked *(either mode)*
also hold an observed campaign:

- no verdict yet (`copy_review_pending`)
- the reviewer said `rewrite` (a proposal for a person to adopt in code; the reviewer's text is never sent)
- the reviewer said `refuse` *(either mode)*
- a retired frame (`copy_retired`) *(either mode)*
- a verdict signed by any other key, a verdict for other bytes, another campaign, another frame, another rubric
- an `approve` that did not come from the reviewer model (the test stand-in can sign a refusal, never a send)
- a body that trips the code lint (accusation words anywhere; a reason word or a missing resubmit line in a denial;
  "nothing is needed from you" on a received or verifying note), whatever the model said *(either mode)*
- a gate that cannot run (missing rubric, missing signers file, missing or malformed mode table, unreadable store)
  *(either mode)*

There is no flag or variable that skips it; the only way a campaign's unreviewed copy sends is the observe row of the
reviewed table. Re-check one approval by hand:

```
python3 -I scripts/outbound_copy/gate.py verify --statement <store>/verdicts/<name>.json --signature <same>.json.sig
```

## What is behind it

| sender | how it asks |
|---|---|
| `scripts/intercom-verify-request.sh` (every verify / status / ask / decline / claim campaign) | directly, after the ledger claim and before its one customer POST |
| `scripts/resolution-matcher.py`, `close-duplicate-conversations.py`, `dedup/sweeps/notify-merged-customers.py` | `scripts/lib/copy_gate.py` `require()`, first statement of the one function that POSTs |
| `scripts/request_comms/channels.py` (Intercom message and the email status line) | `copy_hold()`; a hold is a `rejected` send, retried next tick |
| `scripts/intercom-ops-write.sh reply --agent <id> --gate-campaign <campaign>` (a reply an agent wrote, with no person approving it) | the writer runs `check` itself on the bytes it is about to post; see "A reply an agent wrote" below |

| `scripts/resolve-notify.py`, `overdue-verification-notifier.py`, `merge-outcome-notify.py` | `scripts/outbound_copy/sendgate.py` `require_verdict()`, above the POST in the function that holds it (wiring from hydra #1891, landed in the same tree as the gate) |

`lib/copy_gate.py` and `outbound_copy/sendgate.py` are two callers of the one `gate.py check`; both raise unless it
approved those exact bytes. Every file that can send to a customer is one row in `policies/outbound-copy-senders.json`
(`gated`, `gated_elsewhere` with the test that proves it, or `open` with an owner), and
`scripts/check-outbound-copy-gate.py` fails CI when a sender is on no list, when a `gated` function can reach its POST
without asking, or when a sender that was behind the gate at the base is not any more. It prints every `open` row on
each run.

**Not behind it** (named in `scripts/tests/test_outbound_copy_gate.py`, which fails when a new direct Intercom sender
appears that is on neither list):

- Caroline's live replies (`plugins/intercom/src/outbound.ts`, `scripts/intercom-webhook.js`): a conversation cannot
  wait a review round. They stay under the code output guard and the answer bank.
- The other two classes of `scripts/intercom-ops-write.sh` and what leaves through them: a staff reply a named
  person approved (`--approved-by`), the GDPR pipeline's letters (`scripts/gdpr_pipeline/send.py`, until that lane
  wires its `gdpr-*` campaigns), `intercom-backlog/send.py`, the rights-holder watchdog.
- Mail that is not ours to word here: core's own status emails (`credits_accepted`, `credits_rejected`, the claim
  pair), `legal-intake.py`, `paid-status/email_route.py`, and the notify-gateway bell catalog.

## The four messages

Copy lives in code, one place per sender. These are the words as they stand in this tree.

| stage | who sends it | the words |
|---|---|---|
| Received | `status-doc-received --copy received` | "Hi {name}, a quick update on your credit request for {track}: we have the document you sent, and it's in our review queue. We'll message you here as soon as it's checked." |
| Still verifying | `status-team-review` | "Hi {name}, a quick update on your credit request for {track}: it's with our team for review, and we'll message you here as soon as it's been checked." |
| Done | core's `credits_accepted` email | core is the sender of record for an approval; hydra sends no second note |
| Denied | `decline` | "Hi {name}," / "We finished checking your credit request. For now the credit is denied: the verification didn't prove out." / "You can resubmit for the credit again later." / "Muso.AI" |

The denial gives no reason, makes no accusation, and always carries the resubmit line. `decline_copy_guard` in the
sender and `lint()` in the gate both refuse a reason word; the gate also refuses a denial without "resubmit". The
plural and the claim forms follow the same three sentences.

A received or verifying note never says "nothing is needed from you" / "no need to send anything" (captain bar
2026-10-30, after 21 of 22 people told that owed a document). The sender's copy already dropped the sentence
(`fable-copy-1030-r5/g`, `/k`); the gate's lint now refuses it in either mode, and the rubric tells the reviewer not
to ask for it. The disabled `verifying` lines in `policies/request-status-lines.json` still carry it and cannot send
as written.

The `decline` campaign is still locked in production by `DECLINE_CORE_ROUTE_OFF=0`: core's `credits_rejected` email is
the one denial a person gets while core's route is on, and its wording is core's, not this gate's.

## Rubrics

`policies/outbound-copy-rubric.md` is the default. A message family with different duties gets its own file
(`policies/outbound-copy-rubric-<family>.md`) and one row per campaign in `RUBRIC_FAMILY` in `gate.py`. The family is
chosen by that table, never by the caller. A listed family whose file is missing makes the gate fail (exit 2, held);
it is never reviewed under the default rubric instead. A campaign with its own family is enforced whatever the mode
table says. Two families exist: `gdpr` (the statutory letters) and `support` (the campaign `agent-reply`).

### The default rubric's two classes (captain 2026-11-15)

Rule 3 of the default rubric ("never give a reason for a denial") is scoped, not dropped. The rubric has a section
"The two classes", and the reviewer tells the class from the message itself:

- **Class 1, risk and fraud denials.** Rule 3 in full: denied for now or the verification did not prove out, the
  person can resubmit later, nothing more. The `decline` campaign is this class, and the gate's own lint for the
  `denied` stage (`denial_reason`, `denial_no_resubmit`) is unchanged.
- **Class 2, proof-insufficiency outcomes.** A statement about a document the person sent: the reason, what would
  change it, "Reply to this conversation". It is one fixed sentence per track and one closing, with the three
  approved reason and evidence pairs listed in the rubric. The campaign `proof-refusal` sends it, at stage `ask`.
  The class names five outcomes; wording exists for three, and the rubric tells the reviewer that
  `not_a_document` and `other_role` are not approve until their pair is listed.
- A class 2 message that drifts into class 1 territory (an accusation, fraud, a named internal gate) is refused,
  and a denial that gives a reason is not approved.

This is not a family: `proof-refusal` is reviewed under the default rubric and is enforced by its row in
`policies/outbound-copy-enforce.json` plus the sender's own hold on an `observed` pass.

**Editing the default rubric voids every verdict signed under it.** A verdict names the rubric's sha256, so after
a deploy of a changed `policies/outbound-copy-rubric.md` every body of an enforced campaign is
`copy_review_pending` again until the reviewer host (after `install-reviewer-host.sh`) signs it, and every observed
campaign's rows read `observed:pending`. On 2026-11-15 that was `uvn-reminder-14` and `uvn-new-rows`, both armed.
Plan the reviewer round with the merge.

## A reply an agent wrote

Until 2026-11-14 a customer-facing reply through `scripts/intercom-ops-write.sh` needed `--approved-by` with the
Slack id of one of three people, unless it was an erasure letter. An agent that had the answer for a customer could
not send it, and the scheduled senders that did send passed one person's id on every call, so the audit record said
that person approved a reply nobody had read.

The writer now has a third class. The caller names itself and a campaign, and the writer asks the gate:

```bash
/opt/hydra/scripts/intercom-ops-write.sh reply --conversation <id> \
  --agent <agent-or-job-name> --gate-campaign agent-reply --customer-facing --body-file reply.txt
```

| the gate's answer on these exact bytes | the writer |
|---|---|
| a signed `approve` | posts, and records the agent, the campaign, the verdict id and sha256 and the body sha256 |
| no verdict yet | `HELD`, exit 3: the body is queued for the reviewer, nothing is logged or posted; run the same command again after the next round |
| `rewrite`, `refuse`, a lint hit, a retired frame | `REFUSED`, exit 1: change the copy and submit the new text |
| the gate cannot run or gives no answer | `ERROR`, exit 2 |

- `--validate` asks the gate too and posts nothing, so it is how a caller submits a body and reads its state.
- An `observed` answer is not an approval in this class, in any mode. The verdict is the only approval the reply has.
- The campaigns are a closed list in the writer (`VERDICT_CAMPAIGNS`: `agent-reply`, `backlog-drain`). A verdict
  signed for another sender's copy cannot be posted to an arbitrary conversation through it.
- `agent-reply` is reviewed under `policies/outbound-copy-rubric-support.md`: no promise of a person, no open-ended
  wait, no priority claim, and the reply must end in an answer, a decision, one ask or "we cannot confirm this".
- The same text is never posted twice to one conversation: if a part of ours on file already carries it, the writer
  refuses before the audit record and the POST.
- No request data is declared in this class, and the writer has no flag for it. Elsewhere the sender's code takes
  the declared values from the request row; here the caller writes the body, so a declaration would excuse its own
  words from the lint on its own say-so. A reply that quotes a title or name the lint reads as an accusation is
  refused, and the caller words it another way.
- `--agent` is the caller's own statement of who it is. It is a record, not a control.
- With `--agent`, `--requested-by` and `--approved-by` are refused: the record never names a person.

What the verdict does not cover: the reviewer sees the reply only, so whether a fact in it is true for this customer,
and whether this is the conversation it was written for, are the caller's to answer. One customer message per person
per UTC day is the verify ledger's rule and the caller's to claim; the writer does not read that ledger. A reply
waits for a review round (the reviewer host's timer runs every 15 minutes), so this class is for an answer that is
owed, not for a live chat turn.

**The caller that claims the day is `scripts/intercom-agent-reply.py`** (campaign `agent-reply` in the verify
ledger). It asks `sendgate.require_verdict` about the exact body before it claims anything (a pending review is a
hold that claims nothing), claims the ledger key `conv-<conversation id>` plus the person's day, posts through the
writer above, and finalizes the row `sent` with the verdict id, the verdict sha256 and the campaign; the row's
stamp is `approver_kind=copy-gate`, so it is an authorized send to `audit_stamps` rather than an unstamped finding.
A writer that posted nothing gives the claim back as a `deferred` log, so the same day can try new copy; a writer
whose POST may have landed (`exit 4`, or `exit 0` without its `POSTED` line) keeps the day, and `SKIPPED` names
`daily_cap` or `conversation_already_answered:<campaign>` without reaching the writer at all. It is a dry run
unless given `--apply`. A ledger a pre-check could not read is `REFUSED` with `ledger_unreadable:<error>` (exit 1;
exit 2 on a dry run, and for a ledger that cannot be opened at all), never a skip: "could not read whether this
person was messaged today" is not "they were", and a skip exits 0.

The day is the day the reply lands on, not the day the run started: the claim is made immediately before the POST,
and a claim within ten seconds of UTC midnight waits the boundary out, so a reply cannot be recorded on a day the
customer did not receive it and leave the day it did arrive unclaimed. The writer has no latency bound, so a claim
that crosses midnight anyway is still held: the caller refuses a second reply to the same person within 24 hours of
the last one, whatever day that one is recorded on, and that interval is checked inside the claim's own transaction
(`verify_ledger.claim(min_interval_hours=...)`) rather than in the caller's precheck, so two runs that both passed
the precheck cannot both post. The shared per-day cap (`verify_ledger.capped`) holds the same way for every campaign,
and it holds the day the customer GOT the message, not the day it was claimed: a row carries its claim day, `finalize`
records when the POST landed, and a day on which either falls is held. So a reply claimed at 22:30 and accepted at
00:01 blocks the whole of the next day, and a reply delivered at 23:30 does not block it. An `attempted` row (a writer
that may have posted) holds EVERY day until it is reconciled, because nobody knows when it landed and the writer has no
bounded POST latency. There is no latency window to tune.

Both clauses apply to every sender that asks `capped`, not only this one. Measured on node-8's ledger on 2026-11-15:
1 of 9,280 sent rows was delivered on another day than its claim, and 1 row is `attempted` (uvn-status, claimed
2026-11-04), so one person is held from every campaign until that row is settled. No job settles an `attempted` row
today; a second one appearing is a person to look at, and `SELECT user_key, campaign, day FROM verify_messages WHERE
status='attempted'` lists them. A row finalized `sent` long after its claim also holds the day it is finalized on.

## Running the review

```
python3 scripts/outbound_copy/review_pull.py \
    --remote 'ssh -J root@<jump> root@10.0.0.8' --key ~/.config/muso/outbound-copy-reviewer/id_ed25519
```

Exit 0 = the round completed, 1 = some bodies are still unreviewed (reviewer down or silent, or a message family whose
rubric this host does not have or holds differently from the sender: `unreviewable` names each campaign, how many
bodies it holds and why), 2 = the round could not run (link down, or the two hosts enforce different default
rubrics). A family's rubric is compared per campaign before any of its bodies is reviewed, so one family that cannot
be reviewed never stops the others and never reads as a clean round. Before this, a host installed without
`outbound-copy-rubric-gdpr.md` counted every statutory letter as a bad request and reported `ok` for a day
(2026-11-12: 68 held, none reviewed). It sends nothing. If it does not run, every body of an
enforced campaign stays held and every observed campaign goes out unread: **the review round is the enforced
senders' clock and the only thing measuring the rest.**

So it is a timer, installed from this tree, and its silence is a page:

```
scripts/outbound_copy/install-reviewer-host.sh --remote 'ssh -o BatchMode=yes -J root@<jump> root@10.0.0.8' --enable
```

That copies `gate.py`, `review_pull.py`, the rubrics and the signers file to
`~/.local/share/muso/outbound-copy-review/` (sha256 of each printed, the previous install kept beside it) and writes a
`systemd --user` timer, `outbound-copy-review.timer`, every 15 minutes, up to 60 bodies a round. It refuses a host
whose key is not the pinned reviewer key. Re-run it after any change to `gate.py` or a rubric: the round stops (exit
2) when the two hosts enforce different rules. Undo: the same script with `--uninstall`.

**Order matters when this first deploys.** Enforced senders hold from the moment the gate is on node-8, so the timer
has to be running on the reviewer host before, or the first bodies wait for it.

`scripts/cron-health-watchdog.sh` on node-8 reads `gate.py pending-age` every tick and pages #clio_devops when the
oldest waiting body has waited more than 4 hours (four send ticks on the hourly cron with no round; two
when the tick was 2-hourly), and when a queue it has measured before can no longer be measured (the store is
unreadable, or `gate.py` itself is gone from the host: every sender
asks that file, so a missing gate holds them all). The page says how many of the waiting bodies are **held** (their campaign is
enforced) and never calls an observed campaign's backlog a held customer message. It only reads a number; it releases
nothing.

Limits worth knowing:

- A verify note names the person and their tracks, so almost every body is unique and needs its own verdict. Throughput
  is one reviewer call per 12 bodies.
- A body is held for at least one tick: asked on tick N, reviewed between ticks, sent on tick N+1 if it renders to the
  same bytes. If the person's list changed in between, it is a new body and is reviewed again.
- The reviewer host is a single machine. When it is down, nothing sends, and the watchdog page above is how that is
  noticed. The longer-term shape is a reviewer service inside the cluster behind the same verdict contract.
- At 15 minutes and 60 bodies a round the reviewer can rule about 5,700 bodies a day, above the senders' shared daily
  caps (2,500 credit + 500 claim), so review is not the limiter while the round runs.

Tests: `scripts/tests/test_outbound_copy_gate.py` (the gate, the puller, every Python sender against the real gate, the
ledger hold), the `copy gate` cases in `scripts/tests/intercom-verify-request.bats` (the sender against the real
`gate.py`), and one held-then-sent case each in `test_credit_verify_notify.py`, `tests/test_request_comms.py`,
`tests/test_close_duplicate_conversations.py`. The stalled-round page: the `copy review queue` cases in
`scripts/tests/cron-health-watchdog.bats`, against the real `gate.py`.
