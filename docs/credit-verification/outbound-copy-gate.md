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
means it carries no live traffic); `credit-approved-elsewhere` is enforced from its first byte (no reviewer has read the
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
- `scripts/intercom-ops-write.sh` and what leaves through it: staff replies, the GDPR pipeline's letters
  (`scripts/gdpr_pipeline/send.py`, until that lane wires its `gdpr-*` campaigns), `intercom-backlog/send.py`, the
  rights-holder watchdog.
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
it is never reviewed under the default rubric instead.

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
