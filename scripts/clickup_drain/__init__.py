"""ClickUp support-board drainers: one module per customer-request queue.

Captain 2026-11-03 ~22:3xZ: "every user ticket cleared by code". A drainer reads
the real world read-only (core / Trino, the lane's own ledgers) and writes the
ONE tag that records the customer-visible outcome, then leaves the close to the
surfaces that already own it:

    drainer tag  ->  scripts/clickup-reconcile.py (status `resolved`)
                 ->  scripts/resolve-notify.py (the one approved line)
                 ->  scripts/close-resolved-conversations.py (the Intercom close)

`common.py` is the part every drainer needs identically (identity from the #417
fields, the ledger, the tag write with read-back, the cap, the kill file, the
shared write lock). Nothing in this package sends a customer message: those
belong to the approved senders.

TWO WRITERS OF `status`, and when each is allowed
------------------------------------------------
The ClickUp reconciler (`scripts/clickup-reconcile.py`) owns LINK -> CLASSIFY ->
ACT and is the default closer: it reads a terminal marker off the ticket
(`customer-outcome:complete`, a `merge-outcome:*`) and writes `resolved` itself.

A drainer may close a ticket directly ONLY when it is the writer that knows a
fact the reconciler cannot see on the board — here: the GDPR register's written
confirmation, which lives in a sqlite file, not on the ticket. Two conditions on
that exception:

* it labels first and closes second, so a crash between the two leaves an
  honestly labelled, still-open ticket — never a closed ticket with no outcome;
* it leaves the reason as an internal comment (`notify_all: false`), naming the
  record the close is based on, because a closed ticket with no trace cannot be
  told apart from a human's.

So: while the reconciler would also close a `complete` ticket, it cannot decide
one. A drainer that closes on a tag somebody else wrote, or without recording
what the close rested on, is out of bounds — that is a second writer of the same
decision, not a specialization.

`data_deletion.py` is the `action:data-deletion` drainer; see its docstring.
"""
