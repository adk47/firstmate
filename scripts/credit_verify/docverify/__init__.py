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
VERSION = "dv-4"
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
# FRAUD DENY (captain 2026-10-28 21:3xZ, captain-1028-213x; Fable plan §d): `forged_positive` needs signals
# from TWO of these independent families (gate.fraud_signals). Deliberately NOT signals: a SOFT
# `reused_by_another_account` alone (co-writers send the same split sheet), `reject_pdf_embedded_file`
# (an intake-safety rejection; e-signature PDFs carry attachments), H3's verdict by itself (it aggregates
# these same signals - counting it would count one signal twice), coverage mismatches (track/role not on
# the document) and a person found nowhere. `template` alone never qualifies (R-C5): it needs a second family.
FRAUD_SIGNAL_FAMILY = {
    # the file was edited or assembled
    "reject_polyglot": "file_tamper", "xmp_edit_history_on_screenshot": "file_tamper",
    "editor_software_on_screenshot": "file_tamper", "copy_move_region": "file_tamper",
    "ela_outlier_on_key_field": "file_tamper", "online_editor_producer": "file_tamper",
    "key_field_unique_font": "file_tamper", "signature_not_intact": "file_tamper",
    "after_creation_key_field_edit": "file_tamper",
    # made by a generator
    "ai_generator_software": "ai_generated", "ai_generation_parameters": "ai_generated",
    "ai_generation_workflow": "ai_generated", "c2pa_ai_source": "ai_generated", "iptc_ai_source_type": "ai_generated",
    # the same file used for a competing claim
    "reused_by_another_account_same_claim": "reuse", "reused_on_another_track": "reuse",
    "impersonation_suspected": "reuse",
    # the same template text with other entities on another account (R-C5: never alone)
    "template_family": "template", "template_reused": "template",
    # Fable 165: an F2 text match with other splits / another track is a template (SOFT), not reuse
    "template_match_another_account": "template",
    # facts on the document that cannot be true
    "iswc_check_digit_invalid": "impossible_content", "upc_check_digit_invalid": "impossible_content",
    "document_date_future": "impossible_content", "file_predates_document": "impossible_content",
}
# dv-3 (2026-10-28 23:3xZ) = dv-2 + the FRAUD DENY rule (`forged_positive`). dv-2 was deployed alone at
# 23:06Z (602d8b40) and its carry ran without the fraud-signal criterion, so 26 carried documents with a
# fraud-family signal (2 with two families) were never re-read. dv-3's carry from dv-2 re-reads every
# document with a fraud-family signal in a `forensics` step of ANY earlier version (carried documents only
# have dv-1 steps) and every standing `forged` (it may now be positive); everything else carries - the
# fraud rule cannot change a document with no fraud signal.
CARRY = {"dv-2": ("dv-1", frozenset({"forged", "verified"}), ("xc_domain",)),
         # dv-3 also tightens `verified` (the document itself must name the claimant, and be a document of
         # record): every standing `verified` is re-read as well.
         "dv-3": ("dv-2", frozenset({"forged", "verified"}), (), ("forensics", tuple(sorted(FRAUD_SIGNAL_FAMILY)))),
         # dv-4 (Fable 165, df38bbd1): H3 F2 'reused' is HARD only for the same document (byte-identical, or the same
         # text with the same splits on the same track/ISRC); a template match is SOFT. Only a document H3 called
         # forged can change: every standing forged / forged_positive is re-read, and every document whose
         # forensics carried a hard F2 reuse signal; everything else carries.
         "dv-4": ("dv-3", frozenset({"forged", "forged_positive"}), (),
                  ("forensics", ("reused_by_another_account_same_claim", "reused_on_another_track")))}
