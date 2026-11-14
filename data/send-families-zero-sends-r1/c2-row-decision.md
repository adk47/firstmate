# Decision for the captain: arm the `uvn-status:c2` row

Read on 2026-11-13 from the tick's check artefacts, node-8's live policy and
`docs/credit-verification/verify-request-notes.md` ("Class C is armed by its own row"). This lane
armed nothing and edited nothing on node-8.

## The decision

May the timer send the corrected ask (class C) without a person signing each batch?

**Recommendation: yes, both segments.** The cost and the one condition are at the end.

## What the row is

One entry in node-8's live `/opt/hydra/policies/credit-verify-outbound.json`:

```json
"armed_families": { "uvn-status:c2": {"live": true, "paid": true, "unsigned_from": "<the instant of the decision>"} }
```

Class C is a uvn-status proof ask to a person whose requests one of our earlier status lines already
named ("our team is reviewing", "we received your documents"). The ask opens with the approved
correction, copy `fable-copy-1030-r5/c2`. Without the row the timer passes `--no-correction` and the
gate answers `DEFERRED c2_signed_only`.

node-8 has no such row today. The deployed runner knows the key (9 mentions in the deployed
`credit-verify-outbound.sh`, head `7210fe013`), so adding it does not read as a malformed policy.

## What arming it causes

- From the next tick (one every two hours) the uvn-status apply stops passing `--no-correction` for
  the armed segments. `paid: false` arms free only; `live: false` stops both.
- A person in class C gets the corrected ask by email, as its own message.
- Every other rule still decides each person: documents on file, the approval path, the 90-day ask
  lock, core's own notice inside 7 days, `comm_state`, one message per user per day, the daily caps
  and the per-tick cap of 50 a segment.
- It arms nothing else. A uvn-status family that is dry stays dry.

Who it reaches: 133 of 947 paid and 793 of 2,255 free entries walked on 13 November were answered
`c2_signed_only`, about 926 people (the two lists are rebuilt each tick, so a few may be counted on two
pages). Not all would be sent: that answer is the gate's first, and the later
rules still apply. The lane that built the row estimated about 680 sends (530 to 800) over 7 to 11
armed ticks, about a day; its paid rate rests on 8 users (`data/rapid-verif-final-h3/report.md`).

This is not the first send of the class. 390 corrected asks went on 2026-11-01 (ledger 6338-6994)
and 50 of those people returned a document.

## What stays true while it is unarmed

- Those people get no ask from the timer. They are not refused and nothing is recorded, so they
  are listed again every tick and counted as "on the list, 0 would be messaged".
- The last thing we told each of them is a status line saying a team is reviewing or that documents
  were received. Their request is in `user_verification_needed`, waiting on a document, and
  nothing has told them one is needed.
- A person can still send the class by signing a batch. That is how the 390 went.
- The checks keep paying for it: 1,685 of 2,732 uvn-status gate calls on 12 and 13 November (62%)
  were this one answer.

## What breaks if it is never armed

- They are reached only when a person signs a batch. Otherwise the request stays where it is and
  the earlier status line stands uncorrected.
- The decider change in this PR does nothing for them. It hands documents to stage 2, and a class C
  person reaches the gate only because no document is on file.
- The uvn-status pre-check keeps reading people it will not message, whatever else is fixed. It is
  already the most common answer the gate gives on both uvn-status lists (133 and 793).

## Cost of arming, and the condition

- **Tick length.** Each armed segment adds 25 to 60 minutes of apply to a tick that ran 68 to 76
  minutes. With both segments a tick can pass two hours and cost the next one. `proof-need-ask` runs
  last and is cut or skipped on those ticks (it sent 1 or 2 a tick). That lasts about a day.
- **Copy review.** The uvn-status campaign is in `observe` mode: 171 bodies approved, 1 rewrite, 0
  refused, 0 waiting (`gate.py report`, node-8, 22:52Z). In observe mode a body with no verdict is
  sent and recorded as observed; a signed refusal or a lint hit holds it. I did not check whether a
  rendered /c2 body is among the 171. If the captain's rule is that no corrected ask goes without an
  `approve`, that needs uvn-status moved to `enforce`, a separate one-line change.
- **Undo.** Delete the row or set `live` to false. The tick re-reads the policy at every start; no
  deploy. Sent messages are not recalled.

## How it is placed

By an operator, on node-8, between ticks. That file is live state kept by hand (14 dated `.bak-*`
copies beside it) and the repo's copy has no `armed_families` key, so this is not a PR: a PR that
touched the file would replace the live arming and caps at the next deploy.

```
cp -p /opt/hydra/policies/credit-verify-outbound.json{,.bak-classc-$(date -u +%Y%m%dT%H%MZ)}
jq '.armed_families["uvn-status:c2"] = {"live": true, "paid": true, "unsigned_from": "<instant>"}' \
  /opt/hydra/policies/credit-verify-outbound.json > p.json && install -m 644 p.json /opt/hydra/policies/credit-verify-outbound.json
```

The next tick's log then reads `class C (/c2 corrected asks) ARMED by its row` for each segment.

## Why yes

The copy is approved and has been sent 390 times. Every protective rule still applies to each
person. The exposure is capped at 50 a segment a tick and is undone by deleting one row. Against
that, about 926 people hold a status line from us that is wrong for them, and they have been waiting on a
correction that only a signature releases.
