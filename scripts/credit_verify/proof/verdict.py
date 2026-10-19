"""Deterministic proof verdict (report §7.5; design §5.3).

  FORGED_LIKELY  any hard signal, or a combination rule below.
                 -> N3 (REJECT) + account flag proof_forgery + every pending
                 request of the account held + account review list. (Applied
                 later by the verifier/server; this module only labels.)
  INCONSISTENT   the content contradicts the claim (a mismatch signal):
                 NEEDS_PROOF with the plain reason.
  SUSPECT        a soft signal: NEEDS_PROOF with the reason; never a reject.
  UNDETERMINED   a check could not run (error) and nothing worse was found:
                 an error is never a pass; the proof is analysed again on
                 later runs (store.MAX_ATTEMPTS).
  VERIFIED       clean, names the claimant, shows the claimed track and role,
                 AND an independent issuer signal (a validated other-party
                 e-signature) -> the A3 anchor.
  GENUINE        clean, names the claimant, shows the claimed track and role,
                 no issuer: counts toward approval only in T0/T1 (design §5.3,
                 policy rows 6-7). Proofs are matched to the account, so a
                 document that doesn't name the claimant is never GENUINE,
                 and on a public page (PRO registration, catalog credits
                 page) only a verified identity counts as named.
  PLAUSIBLE      would be GENUINE or VERIFIED, but the document doesn't name
                 the claimant (or the name check could not run: distributor
                 or DSP screenshots, DAW sessions, no usable text, no claimant
                 names; a public page naming only a self-declared name) or
                 its role words can't show the claimed role, or (PDF) its
                 text layer holds a claim match the rendered page does
                 not show (claim_text_not_rendered): never
                 an approval, never an anchor - ranked below GENUINE, above
                 SUSPECT.
Each claimed role (request) gets its own verdict.
  CLEAN_UNLINKED clean, but not linked to a claim yet, so the content could
                 not be cross-checked (Intercom replay before core C1b).

Combinations that make soft signals hard:
  * an edit after creation (F4a key-field edit / online editor) together
    with a content mismatch (F5) -> FORGED_LIKELY;
  * a key field in a unique font family (F4b) together with a key-field edit
    after creation (F4a) -> FORGED_LIKELY;
  * pixel-level paste evidence (F3b) together with a content mismatch (F5)
    -> FORGED_LIKELY;
  * a dashboard that doesn't show the track's artist (F5e soft) together
    with an image editor on the screenshot (F3a soft) -> FORGED_LIKELY.
"""

from __future__ import annotations

from .signals import ERROR, HARD, ISSUER, MISMATCH, POSITIVE, SOFT, ClaimContext, Signal

FORGED_LIKELY, INCONSISTENT, SUSPECT, UNDETERMINED = "FORGED_LIKELY", "INCONSISTENT", "SUSPECT", "UNDETERMINED"
VERIFIED, GENUINE, PLAUSIBLE, CLEAN_UNLINKED = "VERIFIED", "GENUINE", "PLAUSIBLE", "CLEAN_UNLINKED"
VERDICTS = (FORGED_LIKELY, INCONSISTENT, SUSPECT, UNDETERMINED, VERIFIED, GENUINE, PLAUSIBLE, CLEAN_UNLINKED)

EDIT_AFTER_CREATION = {"after_creation_key_field_edit", "online_editor_producer"}
COMBOS = (
    (EDIT_AFTER_CREATION, "MISMATCH", "edited after creation and contradicts the claim"),
    ({"key_field_unique_font"}, {"after_creation_key_field_edit"},
     "a key field in its own font, changed after creation"),
    ({"ela_outlier_on_key_field", "copy_move_region"}, "MISMATCH", "pasted pixels and contradicts the claim"),
    ({"dsp_artist_not_track_artist"}, {"editor_software_on_screenshot", "xmp_edit_history_on_screenshot"},
     "an edited screenshot whose dashboard does not fit the track"),
)


def decide(signals: list[Signal], ctx: ClaimContext) -> tuple[str, list[str]]:
    names = {s.name for s in signals}
    sev = {s.severity for s in signals}
    hard = [s for s in signals if s.severity == HARD]
    if hard:
        return FORGED_LIKELY, [f"{s.check} {s.name}" for s in hard]
    for left, right, why in COMBOS:
        has_left = bool(names & left)
        has_right = (MISMATCH in sev) if right == "MISMATCH" else bool(names & right)
        if has_left and has_right:
            return FORGED_LIKELY, [why]
    mism = [s for s in signals if s.severity == MISMATCH]
    if mism:
        return INCONSISTENT, [s.reason or s.name for s in mism]
    soft = [s for s in signals if s.severity == SOFT]
    if soft:
        return SUSPECT, [f"{s.check} {s.name}" for s in soft]
    errors = [s for s in signals if s.severity == ERROR]
    if errors:
        return UNDETERMINED, [f"{s.check} {s.name}" for s in errors]
    if not ctx.linked:
        return CLEAN_UNLINKED, ["no claim linked: content not cross-checked"]
    positives = [s for s in signals if s.severity == POSITIVE and s.check in ("F5a", "F5b")]
    if not any(s.check == "F5a" for s in positives):
        return SUSPECT, ["nothing in the document ties it to this track"]
    ceiling = [] if "claimant_named" in names else [
        next((s.reason for s in signals if s.name == "claimant_named_unverified"),
             "The document doesn't show your name.")]
    ceiling += [s.reason for s in signals if s.name == "claimed_role_not_expressible"][:1]
    ceiling += [s.reason for s in signals if s.name == "claim_text_not_rendered"][:1]
    if ceiling:
        return PLAUSIBLE, ceiling + [s.name for s in positives]
    if any(s.severity == ISSUER for s in signals):
        return VERIFIED, [s.name for s in signals if s.severity in (ISSUER, POSITIVE)]
    return GENUINE, [s.name for s in positives]
