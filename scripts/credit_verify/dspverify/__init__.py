"""DSP evidence verifier (SHADOW): what independent evidence says about a pending credit request.

For each pending credit request (status unverified) it computes ONE verdict from evidence the user
does not control, and logs it with that evidence to its own append-only store:

  APPROVE   every role it names is credited to the claimant BY ID (the Spotify contributor id / Tidal
            person id already on the Muso profile) in a fresh Spotify AND Tidal capture requested by
            this run, and every request-level guard passed (account gate allow, not big / common /
            flagged, no validator fraud rule, not a duplicate). Only the credited roles are named;
            the rest are a role edit (`role_edit_roles`) - a request is never approved whole on one
            good role.
  DECLINE   every substantive role is contradicted: a one-person role (mix / master / bass / drums
            family) that a COMPLETE fresh Spotify AND Tidal snapshot credits to the same one other
            person, with the claimant linked by id on both and absent from both.
  WAIT      everything else, with the reason class and the `need` code that would settle it
            (needs_profile_link, capture_pending, gate_hold, big_track, org lane, ...).
  DUPLICATE the same account already holds an approved request for this track and role.

UNKNOWN never approves and never declines: a pending, failed, stale or incomplete capture, an
unreadable gate, an unknown popularity are all WAIT.

It never writes to core, never messages anyone, never approves, declines or merges anything: the
verdict is evidence for a later consumer that only the captain can switch on. Rules and their
sources: docs/credit-verification/dsp-evidence-verifier.md.
"""

# Bump when a rule change must re-verify every request (the store keys standing verdicts on it).
VERSION = "dsp-1"
