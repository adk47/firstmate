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
shared write lock). Nothing in this package sends a customer message or writes a
ClickUp status: those belong to the approved senders and to the reconciler.
"""
