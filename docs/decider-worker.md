# The Decider seat

A persistent worker that rules on the classes of decision the captain has already given a standing order for, so most worker questions never cost the captain or the supervisor a turn.
This page owns the seat's charter, its standing orders, how to seat it, and how its definition of done is measured.

It implements the standing-order routing the factory-autonomy rollout specifies: a worker `needs-decision` key that matches a standing-order class goes to the Decider seat, and only class (a) stays with the captain.
Agents load no skill for this; the behavior is a routing check plus a task brief, and both are described here.

## What a decision is, and who owns it

A worker raises a decision by appending one status event, `needs-decision [key=<key>]: <summary>`, and stops until it is answered.
bin/fm-classify-lib.sh owns that grammar and folds the fleet's status logs into the set of open decisions; bin/fm-send.sh owns answering one, through `--resolve-key <key>`, which closes the ledger entry at answer time.

Every open decision falls in exactly one of three buckets, and `bin/fm-decider-lib.sh` is the one owner of the classification:

| Bucket | What it means | Who answers |
| --- | --- | --- |
| class (a) | money, a legal signature, the captain's own logins or clicks, anything irreversible or destructive | the captain, through the normal supervision path |
| a standing order | a decision the captain has already ruled on in kind, so its class has a standing answer | the Decider seat |
| unclassified | anything the classifier cannot place | the captain's normal path, exactly as before this seat existed |

The safe direction is deliberate: an unmatched decision never reaches a worker, and class (a) beats every standing order.
A worker ruling on money, a signature, the captain's credentials, or an irreversible action is the one failure this seat must never make, so the classifier is built to over-assign to the captain rather than under-assign.

### Standing orders

These are the classes the seat may rule on.
`bin/fm-decider-lib.sh`'s `FM_DECIDER_STANDING_ORDERS` is the authoritative list and its classifier owns the patterns; this table explains intent, not matching.

| Class | Standing order |
| --- | --- |
| `refund-under-150` | A refund or credit whose stated amount is explicit and below the cap ($150 by default). Every other money decision is class (a). |
| `additive-ddl` | An additive, reversible schema change: a nullable column, a new index, a created table. |
| `copy-fable-delegated` | User-facing wording the research lane has already approved or delegated. |
| `reversible-hide` | Hide or flag something behind a reversible switch. |
| `user-safe-v4-flip` | Flip a user-safe v4 path on. |
| `merge-on-go` | Merge an already-approved PR once its checks are green. |

Two rules keep the list honest.
A class is only a standing order while its name is in `FM_DECIDER_STANDING_ORDERS`; adding a class is a code change with a test, not a configuration edit.
The seat may always decline: a normalized class is permission to rule, never an obligation to.

## Seating it

The seat is a long-lived task in this home, plus two local pieces of configuration.
It is a seat rather than a work item: nothing dispatches it, it has no backlog entry and no definition of done, and an empty inbox is the healthy state.

1. Write the seat's task id into `config/decider-task` (first non-empty, non-comment line).
   An explicit `FM_DECIDER_TASK` overrides the file for one invocation.
   With no seat configured, nothing is routed and every decision keeps its old path.
2. Seat it with the charter below as its brief, through the ordinary spawn path: a worker with nothing to land and a project it may read for facts.
   It answers through `bin/fm-send.sh --resolve-key`, which writes this home's own ledger, so a seat belongs to exactly one home: the primary's seat cannot answer a secondmate home's decisions, and a home that wants routing seats its own.
   The seat is idle by default: an empty inbox is healthy, and it must never survey, audit, or invent work.
3. Arm the routing check in the captain's own turn: `bin/fm-decider-route.sh arm`.
   It primes the fleet's incremental open-decision read (the first read of a home folds its whole status history, which must never happen inside a bounded watcher check), writes `state/decider-route.check.sh`, and binds its bytes.
   `bin/fm-decider-route.sh disarm` retires the shim and its binding and leaves the routing ledger in place.
4. Check it with `bin/fm-decider-route.sh status`: every open decision with its class and where it will go.

`bin/fm-decider-route.sh sweep` is what the check runs.
It reads the open set once, classifies anything it has not seen, delivers one ruling request per new standing-order decision to the seat's steering inbox, and prints a line only when something needs the supervisor: a delivery failure, a decision that has outlived the ruling window, a configured seat with no task record, or an armed check with no seat configured.

Routing is idempotent per episode.
A decision is asked about once; a key that closes and later reopens is a new episode with its own clock.

## The seat's charter

Give the seat this brief, with `{HOME}` replaced by this firstmate home's absolute path.

```text
You are the Decider seat for {HOME}. You rule, quickly, on the classes of
decision the captain has already given a standing order for, and you rule on
nothing else.

Your inbox is {HOME}/state/<your-task-id>.inbox/. List it, act on the records in
numeric order, and move each one to handled/ when you are done with it. Each
record names one decision: a task, a decision key, and the question.

Answer with:
  bin/fm-decider-route.sh answer <task> <key> '<your ruling>'

That command closes the decision's ledger entry in the same send, which is the
whole point of the seat: a ruling you record any other way leaves the decision
open and the captain still owns it. Write the ruling as the instruction the
worker should act on, in one or two sentences, with any bound the worker must
respect.

Never rule on any of these, whatever the request looks like:
- money of any kind except a refund whose stated amount is under the cap and
  clearly reversible; a discount, a price, a budget, a subscription, or a spend
  decision belongs to the captain;
- anything that is a legal signature, contract, or terms acceptance;
- the captain's own logins, credentials, or clicks (a console, a vendor portal,
  an app store, an API key, a token);
- anything irreversible or destructive: a merge that cannot be reverted, a
  delete, a purge, a rotation, a revoke, a decommission, a force-push.
If a request is really one of those, do not answer it. Leave the decision open
and append one line to your own status log instead:
  note: <task> [key=<key>] needs the captain - <one line why>
That is how the captain inherits it.

Bound your own work: no project edits, no PR merges, no daemon restarts, no
--yes to any tool, and no reading of another worker's chat. You answer decisions
from the question as asked and from the repository if you need a fact; you do
not implement.

Work the inbox, then stop. An empty inbox is the normal state.
```

The seat's rulings are recorded in `state/decider-ledger.tsv`, which is what it is measured on, so an unrecorded ruling is invisible work.

## Measuring it

`bin/fm-decider-metrics.sh report` (optionally `--days <n>`, `--json`) prints the definition of done:

> 80% of the decisions routed to the seat are ruled inside the window (2 hours by default) without a supervisor turn.

Only `answer` records a ruling, so the headline counts exactly the decisions the seat closed itself.
A decision closed some other way (the worker resolved it, the captain answered, the task was cleaned up) is reported as `closed without a ruling` and is deliberately not counted as a win, because a quiet log must never read as a fast decider.
`bin/fm-decider-lib.sh` documents the ledger's record format, and `state/decider-ledger.tsv` is the only input: the report never scans the fleet.

## Drift and limits

The classifier is a keyword model over each decision's key and note, so it is only as good as the vocabulary in `bin/fm-decider-lib.sh`.
Two consequences are permanent and intended:

- A class (a) decision is never routed, even when its note also matches a standing order, because class (a) is tested first. If the seat ever sees a question about money, a signature, credentials, or an irreversible action, that is a routing defect: disarm with `bin/fm-decider-route.sh disarm`, fix the classifier with a test, and re-arm.
- A standing-order decision the classifier cannot place simply stays with the captain. The cost is the captain's time, not safety, and the weekly report is where that cost shows up as a growing `unclassified` count.

The routing ledger is the seat's own record, never a decision authority: whether a decision is still open is answered only by the status-log fold.
Deleting the ledger stops nothing and loses only the measurement.
