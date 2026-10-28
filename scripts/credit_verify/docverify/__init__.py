"""Doc-verify: do not take a returned document at face value.

Every document a user returns for a credit request passes this step before
any approval reads it. The H3 forensics (credit_verify.proof) say whether the
FILE looks tampered with; doc-verify asks whether what the document CLAIMS is
true, from sources the user does not control:

  1. extract    - issuer, signatory, sender email/domain, tracks, ISRCs, roles,
                  dates and amounts, as structured JSON with a confidence per
                  field (OpenRouter deepseek-v4.1-flash-1017; tool-less, the
                  document is data);
  2. forensics  - the H3 verdict and signals for the file, plus file dates vs
                  the dates the document claims, email screenshots (weak) vs
                  original .eml files, and cross-account template reuse;
  3. crosscheck - the claimed credit on Spotify/Tidal (Muso's trusted raw
                  credits), MusicBrainz and Deezer by ISRC, the release's label
                  line vs the claimed issuer, the sender domain vs the issuer's
                  official domain (found independently, never from the
                  document) and its MX, and the signatory on the issuer's site.

Outcome per document and claimed role (gate.py): verified | contradicted |
forged | unverifiable. Only `verified` can ever feed an approval, and only
under the account-level band; UNKNOWN never approves. Nothing is sent to
anybody: no issuer email and no customer copy (captain 2026-10-26 23:30Z).
Design and operator view: docs/credit-verification/doc-verify.md.
"""

# Bump when a rule change must re-verify documents; the deployed reader then re-reads them itself.
VERSION = "dv-2"
# The bump's carry-forward (store.carry_forward, done once by the first reader that opens the store):
# {new version: (previous version, outcomes that send a document back, steps that send it back)}.
# A document carries (its rows copied, marked `carried_from`) only when NONE of its standing outcomes is
# in the outcome set AND none of the named steps RAN for it (status other than skipped) under the
# previous version; every other document is re-read by the deployed reader.
# dv-2 (proof-loop lead 2026-10-28 075; rules #1452/#1457): an unreal-TLD sender is unreadable (need
# readable_document, blocks verified) and a domain-only `forged` needs >= 0.8 + a second signal. Both
# act only through xc_domain: a document whose sender check never ran (no sender address) cannot change
# at all, so it carries. Every document whose sender check ran is re-read - its outcome, need or reason
# may change (QA #1466: an unverifiable email with a low-confidence '.ora' sender keeps the wrong need
# otherwise) - and so is every standing forged or verified. A rule change that can alter ANY outcome
# sets the outcome set to None: then nothing carries.
CARRY = {"dv-2": ("dv-1", frozenset({"forged", "verified"}), ("xc_domain",))}
