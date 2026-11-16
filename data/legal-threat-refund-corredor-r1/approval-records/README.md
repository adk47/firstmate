These two records are **staged, not applied**. They are here so the work is visible and reviewable; nothing
runs them.

- The wrapper refuses both: `scripts/muso-stripe-write.sh` requires `.legal_threat == false` on a record, and
  these say `true`, because this customer wrote a legal-action sentence on 2026-05-17.
- The class is Aaron's to authorize, and **he answered on 2026-11-15: the wall does not move.** A refund paid after a
  legal threat is a settlement, not a refund, and the caps do not authorize it. The earlier yes/no (inbox
  `legal-threat-refund-corredor-r1/011`, 2026-11-15T07:52:41Z; restated in `/014`, 2026-11-15T09:51:45Z) is closed.
- A refund would need a **fresh, case-specific authorization** from him, quoted with its date in a one-line follow-up
  PR that lifts the wall for this case. Nothing in this directory is that authorization, and nothing here runs on the
  strength of the 11-15 answer.
- Nothing is armed either: `/etc/hydra/refund-machine-approvals/` does not exist on node-8, and
  these files are not in it.

The reason on each record is the `staged_reason` field.

## Signing

A record is an approval only when the reviewer key signs those exact bytes. `scripts/muso-stripe-write.sh` verifies
`<record>.json.sig` against `policies/refund-approval-reviewer.allowed_signers`, `-I outbound-copy-reviewer`, namespace
`muso-refund-approval-v1`, and refuses an unsigned record, a record edited after signing, a record signed by another
key, and a copy-gate verdict replayed as an approval. The signing key is the copy gate's reviewer key, which lives on
the reviewer host only, so a root process on node-8 can write a record but cannot make one an approval.

Sign on that host, never here:

    ./scripts/sign-refund-approval.sh data/legal-threat-refund-corredor-r1/approval-records/<record>.json

The signer refuses a record whose `legal_settlement`, `formal_claim` or `legal_threat` is not false, so both records
in this directory cannot be signed while they say `legal_threat: true`. They stay staged and unsigned until the
captain's ruling changes what they may say.
