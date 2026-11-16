Tier: 1, because it changes only a read-only measurement script and its tests: no sender, no cron payload, no customer-facing copy, and the reader still sends nothing. Same tier and reasoning as #2005 and #2028, which added the same reader.

## What

Item D of `plan-everything-ends-20261115.md` — "every open conversation classified into the four states or none; none is the lingering count and it is the number that must fall" — as a `census` subcommand of `scripts/caroline_coach.py`.

Every open conversation is put in exactly one of `answered` / `decided` / `waiting_on_customer` / `closed_stale`, or in `none`, read from the thread's **last message** by an ordered rule table:

- `none` / `customer_last` — the customer spoke last, so we owe the next word.
- `closed_stale` — we spoke last and the customer has been silent 90 days.
- `none` / `holding_line` — the backlog drain's *"Sorry, we did not reply to this message when you sent it ... reply here and tell us what you need"*.
- `none` / `promise_no_person` — *"I'm pulling in a teammate to take this from here"*, the line that promises a person who does not exist.
- `decided` — an approve, or a refuse that carries what would change it ("you can resubmit for the credit again later"). A bare "your request was denied" is `none`/`refusal_no_way_forward`: a refusal with nothing to do next is a dead end, not a decision. A refusal is never required to carry a **reason** — the doctrine forbids explaining why a request failed ("Never explain the JUDGEMENT"), so a way forward is the whole of what a refusal can say, and the answer bank's own batch-decision copy ("The others were denied for now. You can resubmit for those credits again later.") is `decided`.
- `waiting_on_customer` — one named item the customer has to send or do (a question mark is the strongest form of it), including the GDPR acknowledgement whose step 1 is "confirm it's you".
- `none` / `only_cannot` — a "cannot" with no next step behind it. A dead end is not an answer.
- `none` / `not_english` — a line in a language these English rules cannot read. The language check runs **before** any English pattern, so a question mark in another language is never read as a named ask.
- `none` / `unclassified` — a line no rule matched. `answered` is an explicit rule built from the shapes Caroline actually sends, never a default: "We are looking into this." gives no fact and names no next step, and counting it as answered would lower the lingering number while nothing was answered.

The two holding lines are `none` on purpose and are named separately. Counting either as `waiting_on_customer` would make the lingering number fall while nothing was answered: one asks the customer to restate a question we already have, the other promises a person who does not exist.

It also carries the two things Item D asks for beside the states: **humans-assigned** (a person holding the thread, from the monitor's own `read_events`, never a second rule) and **the hour's frustration by shape** — the top five things customers are angry about right now, which is `data/caroline-coach-c1/inbox/012.msg`.

Cost: the full inbox is read once (9,759 open, ~7 minutes at the collector's six read workers) and after that **only the threads whose `updated_at` moved**, cached in a local sqlite keyed on that plus `CENSUS_VERSION` — a changed rule re-reads every thread instead of serving the previous rule set's answers. `facts.updated_at` is Intercom's thread timestamp, not the row's write time: the monitor keeps it so that "a thread whose `updated_at` has not moved is not fetched again" (`caroline_monitor/store.py`), and it moves on every change to the thread, a reassignment with no new message included. Measured: a repeat run reads 0 threads and serves 9,759 from cache. A cache that cannot be written still gives a reading; facts that cannot be read are `NOT MEASURED` with the reason and never zeros.

## Why

That number did not exist. The lane could count signals over the threads it read (48 aging ones a tick) but nobody could say how many of the 9,742 open conversations had ended in a state at all, and "open with no terminal state" is the number the whole plan is measured on.

The classification is not guessed from a sample: it is the senders' own copy, matched by shapes read off node-8's real threads, and the fail-closed buckets are named rather than folded in. Two of them are findings in their own right and are the reason the rule table is ordered this way:

- **1,367 open conversations end on the hand-off line that promises a person who does not exist.** No job will ever answer those; they are the `person_without_assignment` shape at scale.
- **527 open conversations end with a line in a language these rules cannot read** — Caroline answers in the customer's language, so a third of her outbound lines are not English. They are counted as `not_english` and never read as settled. That is a named gap, not a zero.

First real reading, node-8 (`ovh-node-8`), 2026-11-16T00:21:50Z, 9,772 open, 0 read errors:

```
none 3,575 (promise_no_person 1,377, customer_last 910, not_english 527, holding_line 414, unclassified 199, only_cannot 128, no_message 16, refusal_no_way_forward 4)
answered 2,386 | decided 1,652 | waiting-on-customer 1,265 | closed-stale 894
humans-assigned 0
frustrated this hour 0 (measured: 30 customer messages in open threads in 3h, none matched)
```

A second run with nothing changed reads **0 threads and serves all 9,772 from cache**.

`unclassified` is 199 of 9,772 (2.0%) and is named rather than folded into a state. It was 1,786 before the rule table was built from the real shapes; the residual is varied prose, and it is the number to watch if the census ever starts under-reporting.

## Test

`tests/test_caroline_coach.py` — 36 new cases, 77 in the file, all passing. Every Caroline line in the new class is a real one, read from node-8's open conversations on 2026-11-15:

- the drain's holding line is `none` and never `waiting_on_customer`;
- the hand-off line is `none` because the person it promises does not exist;
- a refuse with its reason and what would change it is `decided`;
- a question naming one item, and a GDPR acknowledgement whose step 1 is "confirm it's you", are `waiting_on_customer`;
- a status answer and a short closing line ("You got it, Gadzu.") are `answered`;
- a Russian line, a Spanish line and a Spanish question ("¿Puedes ayudarme?") are `none`/`not_english`, never `answered` and never a named ask;
- a line no rule matches ("We are looking into this.") is `none`/`unclassified`, never `answered`;
- a cached answer becomes `closed_stale` when the 90 days pass, because the boundary is time and not a change to the thread;
- a thread that could not be read is `unread`, `complete` is false, and the line says PARTIAL;
- a "cannot" with no next step is `none`/`only_cannot`, and one that names where the outcome comes from is `answered`;
- a "cannot" followed by a courtesy invitation ("Let me know if you have any other questions", "Reply here if you need anything else") is still `none`/`only_cannot`, because a courtesy is not a way forward;
- a courtesy sentence never settles a thread that said nothing: "We are looking into this. Any other questions?" and "We are looking into this. Let me know if you need anything else." are both `none`/`unclassified`, while "Your profile is now verified. Let me know if you need anything else." is still `answered`;
- a bare "could you" with no item after it ("Could you let us know if you have any other questions?") is not a named ask, while "Could you send us your agreement?" and "Could you tell us which track you meant?" are;
- a name or a title inside an English reply ("Your profile for De La Cruz is now verified.", "The track La Vida is now on your profile.") is `answered`, because a long line is decided by its English function words and not by one token that is also a Spanish word;
- a bare refusal is `none`/`refusal_no_way_forward`, and the approved decline paragraph (which says what would change it) is `decided`;
- a refusal that names an item to send ("We cannot approve this without proof. Could you send us your agreement?") is `waiting_on_customer`, while a refusal ending on a courtesy question ("Any other questions?") stays a dead end;
- a dead-end "cannot" that ends on a courtesy line ("I cannot remove this. Thanks for the details.") is `none`/`only_cannot`, never `answered`;
- a reassignment with no new message invalidates the cache, so `humans_assigned` cannot go stale;
- the customer speaking last is `none`/`customer_last`; we spoke last 90 days ago is `closed_stale`;
- a person holding the thread is counted apart in `humans_assigned`;
- the line puts `none` first and carries humans-assigned, the hour's frustration, and **how old the facts it read are** (the census reads the monitor's facts file, so it is only as fresh as the monitor's last pass — a reading served from an 85-minute-old file is not a reading of the last hour);
- the output carries ids, states and reasons — no message text;
- a second run reads only the threads that changed, a changed thread is read again and its new state wins;
- **a reassignment with no new message invalidates the cache** (the key is the thread's own `updated_at`, which Intercom moves on the assignment);
- a cached answer becomes `closed_stale` once the 90 days pass, without the thread changing;
- a thread that could not be read is counted apart as `unread` and the line says `PARTIAL`, never a lower `none`;
- a question in another language is not read as a named ask;
- **the hour's frustration is read against `now` and never frozen by the cache** (the same cached row, read two hours later, reports zero);
- facts that cannot be read are `NOT MEASURED` and never zero; a cache that cannot be written still gives a reading.

## Credit approval impact

None. This reader approves nothing, decides nothing and sends nothing: it reads Intercom (search and GET) and the monitor's facts file, both read-only, and writes only its own cache and `--out` directory. No decider, approver, ticket kind, sender or customer-facing copy is touched, and no cron payload changes.

Measured on prod data: node-8 (`ovh-node-8`), 9,742 open conversations read at 17:16Z on 2026-11-15. Credit approvals, declines, claims and merges are 0 before and 0 after. The census classifies `decided` 1,679 conversations; it records the state of a thread and writes no decision anywhere.

## Deploy note

`scripts/caroline_coach.py` is run by `caroline-coach.timer` on node-8 (installed by `scripts/install-aux-units.sh`). No new dependency, no new file, no new permission: the cache lives under `/var/lib/hydra/caroline-coach`, which the timer already owns, and the timer already runs as root. **No timer change is in this PR** — `census` is a subcommand a schedule can call; wiring the hourly Item D tick is a separate change.

## Rollback

Revert the commit. The `census` subcommand and its cache are additive; nothing else calls `scripts/caroline_coach.py` and `tick` / `line` / `show` are untouched. Deleting `/var/lib/hydra/caroline-coach/census.sqlite` forces a full re-read.
