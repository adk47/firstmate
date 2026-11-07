"""The Ops summarize/resolve surface (firstmate jan-summarize-resolve-s1).

`summarize.py <conversation_id>` answers "give me a summary and suggest a resolution" with a card
built ONLY from code reads, and `policies/ops-resolutions.json` maps the card's fact pattern to
exactly one action. The card and the lookup are wired into the router's `summarize-resolve`
answerer (`answer.answer_summarize_resolve`), so the Ops bot's Slack ask gets them.

This module EXECUTES NOTHING. When the mapped action is a W1 write the answerer returns a
`WriteRequest` and the router's step 9 runs tier -> fraud lens -> caps -> ledger plan -> writer.
That is the only write path on this surface, and its writers are gated off by captain decision
(`OPS_INTAKE_WRITES`), so a plan is recorded with its inverse and marked as not executed rather
than performed behind a gate nobody opened.

See docs/support/ops-summarize-resolve.md for the doctrine and the ledger schema.
"""

__all__ = [
    "answer",
    "facts",
    "intent",
    "output_guard",
    "resolutions",
    "router",
    "summarize",
]
