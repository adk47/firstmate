"""Profile-merge verifier (SHADOW). See docs/credit-verification/merge-verify.md.

It reads, judges and records. It never merges, unmerges, settles a ledger row, tags a ticket or
messages anyone: the only thing it writes is its own audit store.
"""
