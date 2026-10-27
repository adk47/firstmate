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

# Bump when a rule change must re-verify every document.
VERSION = "dv-1"
