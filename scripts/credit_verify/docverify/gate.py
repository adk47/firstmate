"""Step 5: the outcome per document, request and role. Deterministic: the
model only extracted the claims; these rules decide.

  forged         H3 says FORGED_LIKELY, or a hard forensic signal, or the
                 document's sender is fabricated (a look-alike of the issuer's
                 official domain, or a domain that does not exist).
                 -> decline with the reason + account hold (per rules.md ACCOUNT)
  contradicted   an independent source contradicts the claim: Spotify/Tidal
                 (trusted raw credits) credit this one-person role on the
                 track to someone else.
                 -> decline with the reason + account hold
  verified       ALL of: the claims were extracted (not degraded); the
                 document supports the claim (H3 says GENUINE, VERIFIED or
                 PLAUSIBLE, or H3 says SUSPECT only for coverage - no
                 forensic doubt - and the extracted credits show the claimant
                 in the claimed role family on this track: H3's text matcher
                 misses short OCR'd screenshots); no hard or soft forensic doubt;
                 no soft cross-check (label, domain, MusicBrainz); and an
                 independent source confirms the claimed credit: the trusted
                 DSP credits, or MusicBrainz, credit the claimant in the
                 claimed role family on this track. The account must not be
                 on hold.
                 -> evidence only, never an approval by itself (captain
                    2026-10-27: shadow reader). A consumer still applies its
                    own approve rule and the account-level band. A later
                    account hold supersedes it (store.supersede_verified)
  unknown        our tooling could not decide: extraction did not run (model
                 down, cap, document not located, sandbox failed), H3 missing or
                 UNDETERMINED, Spotify/Tidal credits unreadable. Never asks, never
                 approves, never holds; retried up to 3 runs (D3, Fable 2026-10-27).
  unverifiable   everything else. Never an approval. `need` says which
                 stronger proof would settle it.

A weak finding (email screenshot, free-mail sender) never verifies on its
own; it can stand next to an independent confirmation of the credit.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from . import crosscheck as xc
from .extract import Extraction
from .forensics import HARD, SOFT, Finding

FORGED, CONTRADICTED, VERIFIED, UNVERIFIABLE, UNKNOWN = \
    "forged", "contradicted", "verified", "unverifiable", "unknown"
# Extraction errors that are OUR tooling, not the document (D3): they make the outcome
# `unknown`, which never asks the user, never approves and never holds; it is retried.
TOOLING_ERRORS = ("document not located", "sandbox failed", "daily model spend cap", "no OpenRouter key",
                  "http ", "transport:", "unusable model answer")
APPROVING_H3 = ("GENUINE", "VERIFIED", "PLAUSIBLE")

# Stronger-proof codes for `unverifiable` (machine codes; the copy is not
# written here: captain 2026-10-26 23:30Z, no new customer copy).
NEED_DASHBOARD = "distributor_dashboard_with_code"        # live distributor/DSP dashboard screenshot showing a code we issue
NEED_ISSUER_DOMAIN = "issuer_email_from_official_domain"  # the issuer writes from its official domain, or the original .eml
NEED_COUNTERPARTY = "counterparty_signed_or_registered"   # e-signed envelope with certificate, or a PRO/publisher registration
NEED_READABLE = "readable_document"                       # nothing could be read from the file
NEED_ACCOUNT = "account_on_hold"                          # another document of the account was forged/contradicted

EMAILISH = ("email", "email_screenshot")
DASHBOARDISH = ("dashboard_screenshot", "credits_page", "pro_registration")


@dataclass
class Outcome:
    outcome: str
    reason: str
    need: str | None = None
    account_hold: bool = False
    detail: dict[str, Any] = field(default_factory=dict)


def need_for(ex: Extraction, kind: str | None) -> str:
    if ex.degraded and not ex.emails and not ex.tracks:
        return NEED_READABLE
    if ex.doc_type in EMAILISH or ex.is_email:
        return NEED_ISSUER_DOMAIN
    if ex.doc_type in DASHBOARDISH or kind in ("distributor_portal", "dsp_for_artists"):
        return NEED_DASHBOARD
    if ex.doc_type in ("split_sheet", "contract", "invoice", "letter", "receipt") or kind in (
            "split_sheet", "contract", "invoice", "letter_of_direction"):
        return NEED_COUNTERPARTY
    return NEED_DASHBOARD


FORGED_SENDER_CONFIDENCE = 0.8
SECOND_SIGNAL_H3 = ("FORGED_LIKELY", "INCONSISTENT")


def second_signals(h3_verdict: str | None, findings: list[Finding], checks: list[xc.Check]) -> list[str]:
    """Independent signals that can confirm a fabricated sender (R-C6): forensic doubt on the file, H3
    finding it forged or inconsistent, or a domain-intel flag (young domain, look-alike, free-mail)."""
    out = [f"forensics {f.name}" for f in findings if f.severity in (HARD, SOFT)]
    if h3_verdict in SECOND_SIGNAL_H3:
        out.append(f"H3 {h3_verdict}")
    out += [f"{c.step}" for c in checks if c.step == "xc_domain_intel" and c.status == xc.SOFT]
    return out


def decide(*, h3_verdict: str | None, kind: str | None, ex: Extraction, findings: list[Finding],
           checks: list[xc.Check], account_held: bool, extracted_support: dict[str, Any] | None = None,
           elsewhere: list[str] | None = None) -> Outcome:
    steps = xc.by_step(checks)
    detail = {"h3": h3_verdict, "findings": [f.as_dict() for f in findings],
              "checks": {c.step: c.status for c in checks}}
    hard = [f for f in findings if f.severity == HARD]
    if hard:
        return Outcome(FORGED, f"forensics: {', '.join(f.name for f in hard)}", None, True, detail)
    dom = steps.get("xc_domain")
    fabricated = False
    if dom and dom.status == xc.CONTRADICTS:
        # R-C6 (proof-loop lead 073): the sender domain alone forges only when it was read with confidence
        # >= FORGED_SENDER_CONFIDENCE AND a second, independent signal agrees. Otherwise it is recorded for
        # the watch and decides nothing.
        second = second_signals(h3_verdict, findings, checks)
        conf = dom.detail.get("confidence")
        sure = isinstance(conf, (int, float)) and conf >= FORGED_SENDER_CONFIDENCE
        if sure and second:
            return Outcome(FORGED, f"fabricated sender: {dom.detail.get('note')} ({dom.detail.get('sender_domain')}); "
                                   f"second signal: {', '.join(second)}", None, True, detail)
        fabricated = True
        detail["would_forge"] = {"sender": dom.detail.get("sender_domain"), "note": dom.detail.get("note"),
                                 "confidence": conf, "second_signals": second,
                                 "why_not": ("sender read below %.1f confidence" % FORGED_SENDER_CONFIDENCE)
                                 if not sure else "no second signal (R-C6)"}
    d = steps.get("xc_dsp")
    if d and d.status == xc.CONTRADICTS:
        who = ", ".join(sorted({o.get("name", "") for o in d.detail.get("for_others") or []}))[:120]
        return Outcome(CONTRADICTED, f"Spotify/Tidal credit this {d.detail.get('family')} role on the track to "
                                     f"someone else ({who})", None, True, detail)
    tooling = []
    if (ex.degraded or not ex.ok) and str(ex.error or "").startswith(TOOLING_ERRORS):
        tooling.append(f"extraction did not run ({ex.error})")
    if h3_verdict in (None, "UNDETERMINED"):
        tooling.append(f"H3 {h3_verdict or 'verdict missing'}")
    if d and d.status == xc.ERROR and not any(c.status == xc.POSITIVE for c in checks if c.step == "xc_isrc"):
        tooling.append(f"Spotify/Tidal credits unreadable ({d.detail.get('error')})")
    if tooling:
        return Outcome(UNKNOWN, "tooling: " + "; ".join(tooling)[:500], None, False, detail)
    need = need_for(ex, kind)
    if dom and dom.detail.get("unreadable"):
        need = NEED_READABLE                   # the sender address could not be read: ask for a clearer copy
    if account_held:
        return Outcome(UNVERIFIABLE, "account hold: another document of this account was forged or contradicted",
                       NEED_ACCOUNT, False, detail)
    soft = [f.name for f in findings if f.severity == SOFT]
    soft_xc = [c.step for c in checks if c.status == xc.SOFT]
    confirmed = [c.step for c in checks if c.step in ("xc_dsp", "xc_isrc") and c.status == xc.POSITIVE]
    blockers = []
    if ex.degraded or not ex.ok:
        blockers.append(f"claims not extracted ({ex.error or 'degraded'})")
    if h3_verdict not in APPROVING_H3 and not (h3_verdict == "SUSPECT" and extracted_support and not soft):
        blockers.append(f"H3 verdict {h3_verdict or 'missing'}" + ("" if h3_verdict != "SUSPECT" else
                        " and the extracted credits do not show the claimant in this role on this track"))
    if soft:
        blockers.append("forensic doubt: " + ", ".join(soft))
    if soft_xc:
        blockers.append("cross-check doubt: " + ", ".join(soft_xc))
    if not confirmed:
        blockers.append("no independent source confirms the credit")
    if elsewhere and not extracted_support and h3_verdict not in APPROVING_H3:
        blockers.insert(0, "the document credits the claimant on other tracks (" + ", ".join(
            f"“{t}”" for t in elsewhere) + "), not on this one")
    if fabricated:                             # one signal: not a forgery, never a verification either
        blockers.insert(0, f"sender doubt: {dom.detail.get('note')} ({dom.detail.get('sender_domain')}), "
                           f"{detail['would_forge']['why_not']}")
    if blockers:
        return Outcome(UNVERIFIABLE, "; ".join(blockers)[:600], need, False, detail)
    how = f"H3 {h3_verdict}" if h3_verdict in APPROVING_H3 else \
        f"H3 {h3_verdict} (coverage only), extracted credit {extracted_support}"
    return Outcome(VERIFIED, "independently confirmed by " + ", ".join(confirmed) + f"; {how}; "
                   "no forensic or cross-check doubt", None, False, detail)
