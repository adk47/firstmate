# Caroline's daily resolution rate, and who is still waiting

One line a day in `#clio_devops`, at 06:30 UTC (`support-resolution-daily.timer`). Captain 2026-11-12: "our AI
support must be way way better". This is the number that says whether it is.

| | |
|---|---|
| Measurement | `scripts/support-resolution-daily.py` |
| Wrapper (posts the line) | `scripts/support-resolution-daily.sh` |
| Units | `support-resolution-daily.{service,timer}`, written by `scripts/install-aux-units.sh` |
| Day records (counts only) | `/var/lib/hydra/support-resolution/YYYY-MM-DD.json` |
| Tests | `tests/test_support_resolution_daily.py`, `scripts/tests/support-resolution-daily.bats` |
| Baseline and the cause histogram | `data/ai-support-quality-v1/report.md` |

It is read-only: it searches and reads Intercom conversations and reads the safety ledger. It sends nothing to a
customer, closes nothing, tags nothing and calls no model. The reader refuses any other Intercom call before the
network is touched.

## What the two numbers mean

**Resolution rate.** Of the conversations where a customer wrote in the last 24 hours, the share Caroline answered
with nothing left waiting. Counting from the customer's first message in the window, a conversation is NOT resolved
when:

- nobody replied, or the customer's last message has no reply;
- she said a person is coming, or a person was assigned;
- she, or any sender posting as her, parked it on a queue or holding line ("it is with the verification team",
  "your message is here and it will be read");
- the output guard replaced her reply with the fallback line;
- she refused;
- an earlier promise of a person is still open, whatever she said today; or
- a person replied. The rate is Caroline's, so a conversation a person answered (alone, or after her) is counted
  separately as "answered by a person". It is not her resolution and it is not a customer waiting.

**Answered by a person.** A person's reply settles what came before it: her queue line, her promise of a person,
the guard's fallback line. So a conversation she parked and a person then answered is "answered by a person", not
waiting. It is waiting again only if, after that person's last reply, the customer wrote or she parked it once more.
An assignment or an internal note is not a reply and settles nothing.

**Her own later answer.** It settles less than a person's reply does. Her latest answer decides whether a queue
line, a refusal or the fallback line still stands: if she has since followed one with an answer, the customer was
not left on it. Three limits:

- A bare courtesy ("You're welcome!", "Anytime", "De nada") is a reply but not an answer. It never settles a queue
  line, a refusal or the fallback line before it. The list of courtesies is closed (`COURTESY`, at most 80
  characters). A courtesy in a wording that is not on the list reads as an answer, which errs toward "resolved";
  a short real answer that opens with a listed courtesy reads as a courtesy, which errs toward "waiting".
- A promise of a person is settled only by a person. While one is open, nothing she says later settles anything.
- A refusal on the safety ledger is settled only by an answer of hers more than 120 seconds after the ledger row.
  The line that replaced her refused reply lands within seconds of the row and is not that answer.

**The three buckets.** Every conversation in the window is in exactly one: resolved by Caroline, answered by a
person, or waiting on us. The line prints all three and they add up to the window.

Closing a conversation does not resolve it: the conversation's state is never read. Conversations we wrote to with
no customer message (a bulk notice) are not in the number at all.

**Still waiting.** Two counts that are never added together:

- of that window's conversations, every one that is neither resolved by her nor answered by a person, by reason;
- across the whole open inbox, conversations whose last message is the customer's, by how long they have waited.
  This second count is Intercom's own `waiting_since` field, and any reply clears it, including a holding message.
  Read it as a floor.

## Reading the line

```
Caroline, last 24h to 2026-11-12T00:45Z: resolved 63 of 417 (15.1%). Three buckets that add up to 417: resolved by Caroline 63, answered by a person 0, waiting on us 354 (no reply 48, ...).
Whole inbox, customer wrote last and nobody has replied: 1645 (under 6h 23, 6h to 24h 1, 1 to 7 days 1, over 7 days 1620).
Output guard: 0 refusal(s) explained to her, 0 corrected on retry, 0 retry unusable, 63 ended on the fallback line; ...
Baseline 2026-11-12 under these rules: 63 of 417 (15.1%); it read 58 before an answer after a queue line counted. Rules asq-2026-11-12.5.
```

(That is the baseline day, read before the retry existed: every refusal ended on the fallback line.)

- **"UNMEASURED"** means the read failed (the search, or more than 2 percent of the window's conversations). No rate
  is printed, the unit exits 3 and fails, and `OnFailure` pages. An unmeasured day is never a zero.
- **"ledger NOT READ"** means the Intercom numbers stand and the guard counts are missing, not zero.
- The rules version is in every line and every record. Do not compare two days read under different versions
  without re-reading one of them.

## Changing a phrase changes the number

The phrases that count as a promise of a person, a queue or holding line, or a refusal live in the script
(`PERSON_PROMISE`, `QUEUE_LINE`, `REFUSAL_LINE`). When one changes:

1. Bump `RULES_VERSION`.
2. Re-read the baseline window and confirm what moved, on node-8 (read-only, writes no record):
   `python3 scripts/support-resolution-daily.py --no-record --until 1794444300`
   It must still print `resolved 63 of 417`, or the PR says why it does not and changes `BASELINE` in the script.
3. Add the phrase to the tests.

The baseline has moved once. The captain's brief and the report say 58 of 417 (13.9 percent), which is what rules
`.1` to `.4` read. Rules `.5` read 63 (15.1 percent) on the same conversations: five were counted as waiting on a
queue line that a later message had already answered (three "your credits were approved" notices, one "your
requests were closed, you can reopen them" notice, one question back to the customer). Nothing in the inbox changed
between the two reads. Compare a new day only with the baseline under the same rules, which is the one the line
prints.

This is not hypothetical. On 2026-11-12 at 02Z another sender posted 190 approved holding messages as Caroline to
conversations nobody had answered. Under rules `.1` they read as answers and the day's rate went from 13.9 to 24.9
percent in one hour with nothing deployed. Under `.2` they are holding lines and the same day reads 15.1 percent.
A new bulk sender's wording is the first thing to check when the rate jumps.

## Running it by hand

```
# on node-8: print, do not post, do not write a day record
bash /opt/hydra/scripts/support-resolution-daily.sh --no-post --no-record
# a different window
python3 /opt/hydra/scripts/support-resolution-daily.py --no-record --hours 48
```

Stop it: `systemctl disable --now support-resolution-daily.timer`. Nothing else depends on it.
