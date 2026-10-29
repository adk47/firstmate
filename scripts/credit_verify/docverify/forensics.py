"""Step 2: forensics. The H3 analyzer (credit_verify.proof) already reads the
file: magic bytes, AI-generator and editor metadata, PDF revisions, fonts,
overlays and signatures, error-level and copy-move analysis, and cross-account
reuse by sha256 / perceptual hash / text minhash (F2) and template families
(F2b). This step does not redo any of that; it reads the H3 verdict and
signals for the document and the claim, and adds what needs the extracted
claims:

  file_predates_document   the file was created (PDF CreationDate, EXIF
                           DateTimeOriginal/DateTime) more than 7 days BEFORE
                           the date it says it was signed, issued or sent
                           (SOFT: a template saved early and filled later
                           does this too, so it never forges on its own)
  document_date_future     a signed/issued/sent date after today (SOFT)
  email_screenshot         a picture of an email: who sent it cannot be
                           checked, so it is WEAK evidence and never verifies
                           on its own
  eml_unverified           an original .eml was supplied, but DKIM cannot be
                           checked on node-8 yet (no dkimpy): WEAK as well
  template_reused          H3 F2b: the same template text with different
                           entities from another account (INFO -> SOFT here
                           when the document is a document of record)

Severities: hard (forged), soft (doubt: never verified), weak (cannot verify
on its own), info, positive.
"""

from __future__ import annotations

import re
import sqlite3
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta, timezone
from typing import Any

from credit_verify.proof import FORENSICS_VERSION
from credit_verify.proof.content import AI_SOURCE, RECORD_KINDS

from .extract import Extraction

HARD, SOFT, WEAK, INFO, POSITIVE = "hard", "soft", "weak", "info", "positive"
PREDATE_DAYS = 7
CLAIMED_DATE_KINDS = ("signed", "issued", "sent")
# H3 soft signals that are about what the document covers, not about the file
# itself (same split as stage2.COVERAGE_GAPS).
COVERAGE = frozenset({"track_not_named", "claimed_role_not_listed", "dsp_artist_not_track_artist",
                      "claimed_role_not_expressible", "claimant_named_unverified", "claim_text_not_rendered",
                      "isrc_other_recording", "claimant_not_named", "split_shares_do_not_add_up"})
UNCHECKABLE = frozenset({"reject_unaccepted_type", "reject_too_large", "reject_empty_file", "reject_pixel_bounds"})


@dataclass
class Finding:
    name: str
    severity: str
    detail: Any = None

    def as_dict(self) -> dict[str, Any]:
        return {"name": self.name, "severity": self.severity, "detail": self.detail}


@dataclass
class H3:
    """What H3 recorded for the document and one claim."""
    verdict: str | None
    reasons: list[str] = field(default_factory=list)
    signals: list[dict[str, Any]] = field(default_factory=list)     # {name, severity, check, value, page, region}
    kind: str | None = None

    @property
    def names(self) -> set[str]:
        return {s["name"] for s in self.signals}


def read_h3(proof_db: sqlite3.Connection, proof_id: str, request_key: str) -> H3:
    """The H3 verdict for (proof, '<uuid>#<role>') AS STAGE 2 READS IT.

    The latest current-version verdict row, with exactly the signals H3
    recorded for that claim in the same write (store.record stamps the
    verdict and its forensics rows with one created_at). Then stage 2's own
    rule (stage2.claim_verdict, reused, not copied): a document that does not
    list the track is never FORGED_LIKELY for it because of signals that only
    say it fits another claim (another ISRC, artist or profile name); those
    are coverage gaps. Reading the raw verdict instead called 3 of 89
    backfill documents forged (and held their accounts) where stage 2 says
    review (2026-10-27)."""
    import json

    from credit_verify.proof import stage2
    from credit_verify.proof.pipeline import ProofResult
    from credit_verify.proof.signals import ClaimContext, Signal
    row = proof_db.execute("SELECT verdict, reasons_json, created_at, track_key FROM verdicts WHERE proof_id=? "
                           "AND request_id=? AND analyzer_version=? ORDER BY id DESC LIMIT 1",
                           (proof_id, request_key, FORENSICS_VERSION)).fetchone()
    if row is None:
        return H3(verdict=None)
    verdict, reasons_json, created_at, track_key = row
    from credit_verify.proof.signals import Evidence
    sigs = []
    for c, n, s, r, vj, ej in proof_db.execute(
            "SELECT check_id, name, severity, reason, value_json, evidence_json FROM forensics WHERE proof_id=? "
            "AND request_id=? AND analyzer_version=? AND created_at=?",
            (proof_id, request_key, FORENSICS_VERSION, created_at)):
        try:
            value = json.loads(vj) if vj else None
            ev = json.loads(ej) if ej else {}
        except ValueError:
            value, ev = None, {}
        evidence = Evidence(file="", tool="", page=ev.get("page"), region=ev.get("region")) if ev else None
        sigs.append(Signal(check=c, name=n, severity=s, reason=r or "", value=value, evidence=evidence))
    fp = proof_db.execute("SELECT kind, track_listed FROM fingerprints WHERE proof_id=? AND track_key=? LIMIT 1",
                          (proof_id, track_key or "")).fetchone() or \
        proof_db.execute("SELECT kind, NULL FROM fingerprints WHERE proof_id=? LIMIT 1", (proof_id,)).fetchone()
    kind, listed = (fp[0], None if fp[1] is None else bool(fp[1])) if fp else (None, None)
    try:
        reasons = [str(x) for x in json.loads(reasons_json or "[]")][:6]
    except ValueError:
        reasons = []
    v, reasons, kept = stage2.claim_verdict(
        ProofResult(proof_id, verdict, reasons, sigs, kind or "unknown", None, request_key, listed),
        ClaimContext(request_ids=[request_key], track_title="(linked)"))
    return H3(verdict=v, reasons=list(reasons)[:6], signals=[signal_dict(s) for s in kept], kind=kind)


def signal_dict(s: Any) -> dict[str, Any]:
    """An H3 signal as the reader keeps it: name and severity, plus WHERE it sits - check, value (e.g.
    the key field class), page and region - so the fraud-deny pair can be checked by field and region
    (Fable [key=fraud-deny-families]). No excerpt or file path is kept."""
    ev = getattr(s, "evidence", None)
    d: dict[str, Any] = {"name": s.name, "severity": s.severity, "check": getattr(s, "check", None)}
    if isinstance(getattr(s, "value", None), dict):
        d["value"] = {k: v for k, v in s.value.items() if k in ("field", "fields", "page", "font", "z", "matches")}
    if ev is not None:
        if getattr(ev, "page", None) is not None:
            d["page"] = ev.page
        if getattr(ev, "region", None):
            d["region"] = [float(x) for x in ev.region][:4]
    return d


def where(s: dict[str, Any]) -> dict[str, Any]:
    return {k: s[k] for k in ("check", "value", "page", "region") if s.get(k) not in (None, {}, [])}


def file_date(facts: dict[str, Any]) -> date | None:
    """When the file says it was made: PDF CreationDate ('D:20240131...') or
    EXIF DateTimeOriginal / DateTime ('2024:01:31 12:00:00')."""
    for k in ("created", "exif_datetime_original", "exif_datetime"):
        v = str(facts.get(k) or "")
        m = re.search(r"(\d{4})[:\-]?(\d{2})[:\-]?(\d{2})", v.removeprefix("D:"))
        if m:
            try:
                d = date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
            except ValueError:
                continue
            if 1995 <= d.year <= 2100:
                return d
    return None


def check(h3: H3, ex: Extraction, facts: dict[str, Any], mime: str | None,
          today: date | None = None) -> list[Finding]:
    today = today or datetime.now(timezone.utc).date()
    out: list[Finding] = []
    kind = h3.kind or ""
    # -- H3 ------------------------------------------------------------------
    if h3.verdict is None:
        out.append(Finding("h3_missing", WEAK, "no H3 verdict recorded for this document and claim"))
    elif h3.verdict == "FORGED_LIKELY":
        out.append(Finding("h3_forged", HARD, h3.reasons[:3]))
    elif h3.verdict == "UNDETERMINED":
        out.append(Finding("h3_undetermined", WEAK, h3.reasons[:3]))
    for s in h3.signals:
        if s["severity"] == "hard" and h3.verdict == "FORGED_LIKELY" and s["name"] not in COVERAGE:
            # behind h3_forged: recorded (INFO, decides nothing by itself) WITH where it sits, for the
            # fraud-deny pair (gate.fraud_signals)
            out.append(Finding(f"h3_{s['name']}", INFO, {"note": "hard H3 signal behind h3_forged", **where(s)}))
        elif s["severity"] == "hard" and h3.verdict != "FORGED_LIKELY":
            # H3 decided it is not forged FOR this claim (a coverage case);
            # a hard file signal is still doubt about the file.
            out.append(Finding(f"h3_{s['name']}", SOFT, {"note": "hard H3 signal, not forged for this claim", **where(s)}))
        elif s["severity"] == "soft" and s["name"] not in COVERAGE | UNCHECKABLE | AI_SOURCE:
            out.append(Finding(f"h3_{s['name']}", SOFT, where(s) or None))
        elif s["severity"] == "soft" and s["name"] in AI_SOURCE:
            out.append(Finding(f"h3_{s['name']}", WEAK, "AI-generation metadata on a non-record image"))
        elif s["name"] == "template_family":
            out.append(Finding("template_reused", SOFT if kind in RECORD_KINDS else INFO,
                               "same template text with different entities on another account"))
    # -- dates ---------------------------------------------------------------
    made = file_date(facts)
    for d in ex.dates:
        if d["what"] not in CLAIMED_DATE_KINDS or not d["confidence"] >= 0.6:
            continue
        try:
            claimed = date.fromisoformat(d["date"])
        except ValueError:
            continue
        if claimed > today + timedelta(days=1):
            out.append(Finding("document_date_future", SOFT, {"claimed": d["date"], "what": d["what"]}))
        if made and made + timedelta(days=PREDATE_DAYS) < claimed:
            out.append(Finding("file_predates_document", SOFT,
                               {"file_created": made.isoformat(), "claimed": d["date"], "what": d["what"]}))
    # -- emails --------------------------------------------------------------
    if mime == "message/rfc822":
        out.append(Finding("eml_unverified", WEAK, "original .eml: DKIM not checked on node-8 yet (no dkimpy)"))
    elif ex.is_email or ex.doc_type == "email_screenshot":
        out.append(Finding("email_screenshot", WEAK,
                           "a picture of an email: the sender cannot be authenticated from it"))
    if facts.get("software") and str(mime or "").startswith("image/") and not facts.get("camera"):
        out.append(Finding("screenshot_software", INFO, str(facts["software"])[:80]))
    return out


def worst(findings: list[Finding]) -> str | None:
    for sev in (HARD, SOFT, WEAK):
        if any(f.severity == sev for f in findings):
            return sev
    return None
