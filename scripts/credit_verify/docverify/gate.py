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

import re

from . import FRAUD_SIGNAL_FAMILY
from . import crosscheck as xc
from .extract import Extraction
from .forensics import HARD, INFO, SOFT, Finding

FORGED, CONTRADICTED, VERIFIED, UNVERIFIABLE, UNKNOWN = \
    "forged", "contradicted", "verified", "unverifiable", "unknown"
# FRAUD DENY (captain-1028-213x): two independent signal families agree. Evidence for a decline ONLY after
# a Fable confirm on that document (tray `jan-forged-bN`, ruling `forged-<sha8>`); the reader never writes.
FORGED_POSITIVE = "forged_positive"
_REASON = re.compile(r"^F\w+ ([a-z0-9_]+)")
# Extraction errors that are OUR tooling, not the document (D3): they make the outcome
# `unknown`, which never asks the user, never approves and never holds; it is retried.
TOOLING_ERRORS = ("document not located", "sandbox failed", "daily model spend cap", "no OpenRouter key",
                  "http ", "transport:", "unusable model answer")
APPROVING_H3 = ("GENUINE", "VERIFIED", "PLAUSIBLE")
# The DOCUMENT must prove the credit (verifier-eval-v1 blind labels, 2026-10-28 23:4xZ: all dv-2 `verified`
# rows were documents that prove nothing - DSP/catalog panels, Muso UI, dashboards, chats - passed on H3
# PLAUSIBLE + the Spotify/Tidal cross-check). Only a document of record can verify a credit by itself: a
# registration, a split sheet, a contract, an invoice/receipt, a letter. A public catalog or DSP panel, an
# app or distributor dashboard (self-entered metadata) and an email/social screenshot cannot - a dashboard
# only with our F9 code on it (xc_challenge POSITIVE).
RECORD_DOC_TYPES = ("split_sheet", "contract", "invoice", "letter", "pro_registration", "receipt")
# F9 is evidence only on the document it was made for (QA #1476): a live distributor/DSP dashboard screenshot, as the
# EXTRACTION reads the document type. H3's `kind` is a keyword count (a contract naming DistroKid three times reads
# `distributor_portal`), so it never makes a document a dashboard on its own.
F9_DOC_TYPES = ("dashboard_screenshot",)


def f9_anchor(checks: list[xc.Check], ex: Extraction, kind: str | None) -> bool:
    return (any(c.step == "xc_challenge" and c.status == xc.POSITIVE for c in checks)
            and getattr(ex, "doc_type", None) in F9_DOC_TYPES)
RECORD_H3_KINDS = ("split_sheet", "contract", "invoice", "letter_of_direction", "pro_portal")

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


CLAIM_FIELDS = frozenset({"claimant_name", "isrc", "track", "role", "date"})
# The only file_tamper signals a `template` signal pairs with (Fable 1029 01:56Z): an edit after creation or
# signature, copy-move, ELA on a key field. Every other family (reuse, ai_generated, sender, impossible_content)
# still pairs with template. A font change, an online editor or screenshot-editor metadata never does.
TEMPLATE_TAMPER_PARTNERS = frozenset({"after_creation_key_field_edit", "signature_not_intact", "copy_move_region",
                                      "ela_outlier_on_key_field"})
STATEMENT_ISSUERS = ("distributor", "pro", "dsp")


def claim_fields(kind: str | None, ex: Extraction | None) -> frozenset[str]:
    """The fields that carry the claim on THIS kind of document (Fable [key=fraud-deny-families]
    addendum 21:45Z): claimant name / ISRC-track / role / date always; the SHARE on a split sheet (there
    the share is the claim - a role at 0% is no credit); the AMOUNT on a royalty / distributor statement
    (an edited amount on the only evidence of the credit). Never on a licence, contract or email."""
    doc_type = getattr(ex, "doc_type", None)
    issuer = (getattr(ex, "issuer", None) or {}).get("type") if ex is not None else None
    out = set(CLAIM_FIELDS)
    if kind == "split_sheet" or doc_type == "split_sheet":
        out.add("share_percent")
    statement = kind == "distributor_portal" or (doc_type in ("dashboard_screenshot", "receipt")
                                                 and issuer in STATEMENT_ISSUERS)
    if statement and doc_type not in ("email", "email_screenshot", "contract", "letter"):
        out.add("amount")
    return frozenset(out)


def _located(f: Finding) -> dict[str, Any]:
    d = f.detail if isinstance(f.detail, dict) else {}
    out: dict[str, Any] = {}
    v = d.get("value") if isinstance(d.get("value"), dict) else {}
    fields = ([v["field"]] if v.get("field") else []) + list(v.get("fields") or [])
    if fields:
        out["fields"] = sorted(set(fields))
    if d.get("page") is not None or v.get("page") is not None:
        out["page"] = d.get("page") if d.get("page") is not None else v.get("page")
    if d.get("region"):
        out["region"] = d["region"]
    return out


def fraud_signals(findings: list[Finding], checks: list[xc.Check]) -> list[dict[str, Any]]:
    """The fraud signals on this document (FRAUD_SIGNAL_FAMILY), each {id, family, and where it sits:
    fields / page / region when the analyzer recorded them}: forensic findings (a SOFT or HARD finding,
    or the INFO record of a hard H3 signal behind h3_forged), H3's own reasons when it says forged
    (no location), and the sender (a fabricated address read >= FORGED_SENDER_CONFIDENCE, or a
    domain-intel flag - one family, both are about the same address)."""
    out: dict[str, dict[str, Any]] = {}

    def add(sid: str, fam: str | None, loc: dict[str, Any]) -> None:
        if fam and sid not in out:
            out[sid] = {"id": sid, "family": fam, **loc}
    for f in findings:
        behind_forged = f.severity == INFO and isinstance(f.detail, dict) and \
            str(f.detail.get("note", "")).startswith("hard H3 signal")
        if f.severity in (HARD, SOFT) or behind_forged:
            loc = _located(f)
            key = f.name + (f"@p{loc.get('page')}:{loc.get('region')}" if loc.get("region") else "")
            add(key if loc else f.name, FRAUD_SIGNAL_FAMILY.get(f.name.removeprefix("h3_")), loc)
        if f.name == "h3_forged":
            for r in (f.detail if isinstance(f.detail, list) else []):
                m = _REASON.match(str(r))
                if m and not any(e["id"].startswith(f"h3_{m.group(1)}") for e in out.values()):
                    add(f"h3_{m.group(1)}", FRAUD_SIGNAL_FAMILY.get(m.group(1)), {})
    for c in checks:
        if c.step == "xc_domain" and c.status == xc.CONTRADICTS:
            conf = c.detail.get("confidence")
            if isinstance(conf, (int, float)) and conf >= FORGED_SENDER_CONFIDENCE:
                add(f"xc_domain: {c.detail.get('note')} ({c.detail.get('sender_domain')})", "sender", {})
        elif c.step == "xc_domain_intel" and c.status == xc.SOFT:
            # only a flag on the SENDER's own domain (QA #1470): a look-alike CC / counterparty address on the
            # document says nothing about who sent it. The flag is quoted.
            senders = {str(r.get("domain") or "").lower() for r in c.detail.get("domains") or []
                       if r.get("role") == "sender"}
            for f in c.detail.get("flags") or []:
                if str(f).split(":", 1)[0].strip().lower() in senders:
                    add(f"xc_domain_intel: {str(f)[:120]}", "sender", {})
    return sorted(out.values(), key=lambda e: (e["family"], e["id"]))


def _overlap(a: dict[str, Any], b: dict[str, Any]) -> bool:
    """Two readings of the same edit: same page and intersecting regions (Fable: independence is by
    family AND by region). Signals without a region (template, reuse, sender, generator) never overlap."""
    ra, rb = a.get("region"), b.get("region")
    if not ra or not rb or a.get("page") != b.get("page"):
        return False
    return not (ra[2] < rb[0] or rb[2] < ra[0] or ra[3] < rb[1] or rb[3] < ra[1])


def positive_pair(sigs: list[dict[str, Any]], fields: frozenset[str] | set[str] | list[str] = CLAIM_FIELDS
                  ) -> tuple[dict[str, Any], dict[str, Any]] | None:
    """The first pair that makes a document POSITIVELY forged (captain-1028-213x, Fable
    [key=fraud-deny-families]): two signals of DIFFERENT families, not two readings of one edit, and
    - for file_tamper + template - the tamper signal sits on a field that carries the claim
    (`fields`, from claim_fields(kind, ex); a font change in a footer is not the second family)."""
    for i, a in enumerate(sigs):
        for b in sigs[i + 1:]:
            if a["family"] == b["family"] or _overlap(a, b):
                continue
            # Fable 127 (6d004ade): the file_tamper half of ANY pair sits on a LOCATED claim field - a copy-move
            # on a page counter, UI chrome or a margin, or a document-level flag with no field, never counts.
            if any(e["family"] == "file_tamper" and not set(fields) & set(e.get("fields") or []) for e in (a, b)):
                continue
            fams = {a["family"], b["family"]}
            if fams == {"file_tamper", "template"}:
                tamper = a if a["family"] == "file_tamper" else b
                if not set(fields) & set(tamper.get("fields") or []):
                    continue
                # A template family is 'same text, different entities': its entity blanks are exactly where a
                # filler types, often in another font. A font change is therefore the expected shape of every
                # honestly filled standard form (e9ec352a, e47c9af3, both ruled not): template pairs only with
                # a real edit of the file (TEMPLATE_TAMPER_PARTNERS).
                if tamper["id"].split("@")[0].removeprefix("h3_") not in TEMPLATE_TAMPER_PARTNERS:
                    continue
            return a, b
    return None


def tooling_errors(ex: Extraction, h3_verdict: str | None, checks: list[xc.Check]) -> list[str]:
    """Our own tooling failing (D3): the extraction did not run, H3 is missing or undetermined, or the
    Spotify/Tidal credits could not be read (and no ISRC confirmed). Such a document is `unknown` - and
    never `forged_positive`."""
    d = xc.by_step(checks).get("xc_dsp")
    out = []
    if (ex.degraded or not ex.ok) and str(ex.error or "").startswith(TOOLING_ERRORS):
        out.append(f"extraction did not run ({ex.error})")
    if h3_verdict in (None, "UNDETERMINED"):
        out.append(f"H3 {h3_verdict or 'verdict missing'}")
    if d and d.status == xc.ERROR and not any(c.status == xc.POSITIVE for c in checks if c.step == "xc_isrc"):
        out.append(f"Spotify/Tidal credits unreadable ({d.detail.get('error')})")
    return out


def decide(*, h3_verdict: str | None, kind: str | None, ex: Extraction, findings: list[Finding],
           checks: list[xc.Check], account_held: bool, extracted_support: dict[str, Any] | None = None,
           elsewhere: list[str] | None = None, covers: bool = False) -> Outcome:
    steps = xc.by_step(checks)
    detail = {"h3": h3_verdict, "findings": [f.as_dict() for f in findings],
              "checks": {c.step: c.status for c in checks}}
    sigs = fraud_signals(findings, checks)
    if sigs:
        detail["fraud_signals"] = sigs
    fields = claim_fields(kind, ex)
    pair = positive_pair(sigs, fields)
    pending = tooling_errors(ex, h3_verdict, checks)
    if pair and pending:
        # QA #1470: the captain's deny rule is POSITIVE-only. A pair read while our own tooling failed (no
        # extraction, H3 missing/undetermined, credits unreadable) is not positive: recorded, and the document
        # falls through to a hold (one hard signal) or `unknown` (retried), never forged_positive.
        detail["would_forge_positive"] = {"pair": list(pair), "why_not": "tooling: " + "; ".join(pending)}
        pair = None
    if pair:
        detail["fraud_pair"] = list(pair)
        detail["claim_fields"] = sorted(fields)
        quoted = "; ".join(f"{e['family']}: {e['id']}" + (f" (fields {', '.join(e['fields'])})" if e.get("fields") else "")
                           for e in pair)
        if not covers:
            # A deny reaches ONLY a request the document is tied to (Fable 110, e9ec352a: a producer agreement for
            # one track would have denied four other tracks it never names). For any other request of the
            # account the positively forged document is a HOLD, never a deny.
            detail["positive_document"] = True
            return Outcome(FORGED, f"two independent fraud signals ({quoted}), but the document does not name this "
                                   "request's track: a hold, never a deny"[:600], None, True, detail)
        detail["covers"] = True
        return Outcome(FORGED_POSITIVE, f"two independent fraud signals ({quoted})"[:600], None, True, detail)
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
    tooling = tooling_errors(ex, h3_verdict, checks)
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
    # F9 (proof-loop lead 092): a live dashboard showing the code we issued AND the claimant in this role on
    # this track confirms the credit like a DSP anchor; the code alone (no extracted credit) confirms nothing.
    if extracted_support and f9_anchor(checks, ex, kind):
        confirmed.append("xc_challenge")
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
    # the DOCUMENT must name the claimant in this role on this track - an independent source crediting
    # them is a cross-check of the document, never a substitute for it
    if not extracted_support:
        blockers.append("the document itself does not name the claimant in this role on this track")
    f9 = f9_anchor(checks, ex, kind)
    if not (ex.doc_type in RECORD_DOC_TYPES or kind in RECORD_H3_KINDS or f9):
        blockers.append(f"not a document of record ({ex.doc_type or 'unknown type'}): a catalog/DSP panel, an "
                        "app or dashboard screen, or an email/social screenshot cannot prove a credit by itself")
    if elsewhere and not extracted_support and h3_verdict not in APPROVING_H3:
        blockers.insert(0, "the document credits the claimant on other tracks (" + ", ".join(
            f"“{t}”" for t in elsewhere) + "), not on this one")
    if dom and dom.detail.get("unreadable"):   # a misread sender is never evidence FOR the document (QA #1452)
        blockers.insert(0, f"sender address unreadable ({dom.detail.get('note')})")
    if fabricated:                             # one signal: not a forgery, never a verification either
        blockers.insert(0, f"sender doubt: {dom.detail.get('note')} ({dom.detail.get('sender_domain')}), "
                           f"{detail['would_forge']['why_not']}")
    if blockers:
        return Outcome(UNVERIFIABLE, "; ".join(blockers)[:600], need, False, detail)
    how = (f"H3 {h3_verdict}" if h3_verdict in APPROVING_H3 else f"H3 {h3_verdict} (coverage only)") + \
        f", the document names the claimant ({ex.doc_type})"
    return Outcome(VERIFIED, "independently confirmed by " + ", ".join(confirmed) + f"; {how}; "
                   "no forensic or cross-check doubt", None, False, detail)
