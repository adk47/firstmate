"""JUNK PROOF option C (captain 2026-10-28 21:4xZ, captain-1028-214x; Fable 083/086/088): which filed
documents are not evidence of a credit at all, by artifact kind. Deterministic and conservative: a rule
fires only on a clear marker, and anything unclear is NOT junk.

  muso_ui_screenshot (SYS-001)  a screenshot of Muso's own app or site (the claimant showing us our own
                                screen). Counted separately.
  own_email                     an email from Muso (muso.ai sender, or Muso as the issuer of an email)
  muso_receipt                  Muso's own receipt / invoice (a subscription payment proves no credit)
  unsent_draft                  an email compose window: a draft, never sent
  daw_instrument_photo          a DAW application screen with no credit on it (from the text; a camera photo
                                with little text is NOT enough - it can be a photographed split sheet)
  lease_licence_template        a beat lease / licence template (proves a purchase, not a credit)

This module only CLASSIFIES. The purge of docs_on_file is a feed change (ops-to-ovh-m1) after Fable's
confirm on the list; a decline of a request (standard line, no ask) is only proposed when EVERY document
filed for that request is junk - a real document is never overridden by a junk one (088 asked this for
SYS-001; it is applied to every kind).
"""
from __future__ import annotations

import re
from typing import Any

KINDS = ("muso_ui_screenshot", "own_email", "muso_receipt", "unsent_draft", "daw_instrument_photo",
         "lease_licence_template")
SYS_001 = "muso_ui_screenshot"

_MUSO_UI = re.compile(r"credits\.muso\.ai|app\.muso\.ai|\bmuso\.ai\b.{0,80}\b(credits?|profile|verify|verification|"
                      r"claim|pending|dashboard|roster)\b|\b(add|claim|verify) (your )?(credits?|profile)\b.{0,80}\bmuso",
                      re.I | re.S)
_DRAFT = re.compile(r"\bdraft saved\b|\bdiscard draft\b|\bsaved to drafts\b|\bnew message\b.{0,200}\b(to|subject)\b|"
                    r"^\s*draft\s*$", re.I | re.M | re.S)
_DAW = re.compile(r"\b(pro tools|logic pro|ableton live|fl studio|cubase|studio one|reaper|bitwig)\b", re.I)
# A DAW *application* screen: UI-only tokens (menus, mixer, transport, plug-in names), never prose words like
# `track`, `mix` or `edit` (QA #1472: "I confirm I produced the track ... in Pro Tools" is a statement). At
# least DAW_UI_MIN distinct tokens are needed, and first-person prose is never a screen.
_DAW_UI = re.compile(r"\b(audiosuite|arrangement|mixer|inserts?|sends|transport|bpm|timeline|automation|"
                     r"channel strip|playlist|solo|mute|quantize|metronome|kontakt|serum|omnisphere|auto-?tune|"
                     r"fabfilter|waves|plug-?ins?|vst3?|au)\b", re.I)
DAW_UI_MIN = 2
# An application MENU BAR is UI structure on its own (the words in their menu order, not anywhere in prose)
_DAW_MENU = re.compile(r"\btrack\s+clip\s+event\s+audiosuite\b|\bnavigate\s+record\s+mix\s+view\s+window\b|"
                       r"\bcreate\s+edit\s+capture\s+insert\s+view\s+options\b|\bpatterns\s+view\s+options\s+tools\b",
                       re.I)
_PROSE = re.compile(r"(^|[\s,.;:])I[\s,']|\b(confirm|confirms|confirmed|produced|hereby|certify|declare)\b")
_FILE_HOST = re.compile(r"\b(dropbox|google drive|onedrive|icloud drive|box\.com|wetransfer|search results)\b", re.I)
# Licence/lease TERMS, never a marketplace name alone (QA #1472: a signed producer agreement that mentions
# BeatStars is not a lease template).
_LEASE = re.compile(r"\bnon[- ]exclusive (license|licence)\b|\b(mp3|wav|trackout|stems?|unlimited|premium) "
                    r"(lease|license|licence)\b|\bbeat (lease|license|licence)\b|\blease agreement\b|"
                    r"\bthis (license|licence) is granted\b", re.I)
SCREENISH = ("dashboard_screenshot", "credits_page", "other")
SCREEN_TYPES = ("dashboard_screenshot", "credits_page")      # explicit screen types (the text-less pass)
EMAILISH = ("email", "email_screenshot")


MUSO_DOMAINS = ("muso.ai",)


def muso_domain(domain: str) -> bool:
    """muso.ai itself or a dot-delimited subdomain (mail.muso.ai) - never a look-alike (notmuso.ai, QA #1472)."""
    d = (domain or "").strip().lower().rstrip(".")
    return any(d == m or d.endswith("." + m) for m in MUSO_DOMAINS)


MUSO_ISSUER_NAMES = frozenset({"muso", "muso.ai", "musoai", "muso ai", "muso inc", "muso.ai inc", "muso, inc."})
MUSO_MIN_CONFIDENCE = 0.6


def _sure(part: dict[str, Any]) -> bool:
    try:
        return float(part.get("confidence")) >= MUSO_MIN_CONFIDENCE
    except (TypeError, ValueError):
        return False


def _muso_party(ex: dict[str, Any]) -> bool:
    """Muso itself issued or sent it - read SURE (>= 0.6) and as an EXACT Muso identity (QA #1472): the issuer named
    exactly 'Muso' / 'Muso.AI' (not 'Muso Records'), or a sender address on muso.ai or one of its subdomains."""
    iss = ex.get("issuer") or {}
    name = " ".join(str(iss.get("name") or "").lower().split())
    sender = ex.get("sender") or {}
    email = str(sender.get("email") or "")
    by_name = _sure(iss) and name in MUSO_ISSUER_NAMES
    by_sender = _sure(sender) and (muso_domain(sender.get("domain") or "") or
                                   muso_domain(email.rsplit("@", 1)[-1] if "@" in email else ""))
    return by_name or by_sender


def classify(*, text: str | None, ex: dict[str, Any] | None, facts: dict[str, Any] | None,
             kind: str | None) -> tuple[str | None, str]:
    """(artifact kind or None, why). `text` None = the text was not available (a stored-data pass):
    only the rules that need no text can fire, and the result says so."""
    ex = ex or {}
    facts = facts or {}
    doc_type = ex.get("doc_type")
    has_credit = bool(ex.get("credits")) or bool(ex.get("tracks"))
    is_email = bool(ex.get("is_email")) or doc_type in EMAILISH
    t = text or ""
    if is_email and t and _DRAFT.search(t) and not (ex.get("sender") or {}).get("email"):
        return "unsent_draft", "an email compose window (draft markers, no sender)"
    if _muso_party(ex):
        if is_email:
            return "own_email", "an email from Muso"
        if doc_type in ("invoice", "receipt"):
            return "muso_receipt", "Muso's own receipt or invoice"
        # Credits on it do NOT make it evidence: a screenshot whose ISSUER is Muso is Muso's own record of
        # the claim (Muso's credits page always lists credits - 34 of 51 SYS-001 rows on 10-28 carry them).
        # The no-credit guard below applies only where the issuer is not Muso and Muso UI text fires.
        # An explicit SCREEN type issued by Muso is positive evidence on its own, whatever the OCR caught (QA #1472:
        # 'Credits Pending' on a credits_page is still Muso's screen); `other` needs positive Muso-UI text (a
        # text-less Muso letter of doc_type `other` is not a screenshot).
        if doc_type in SCREEN_TYPES or (t and doc_type == "other" and _MUSO_UI.search(t)):
            return SYS_001, "a screenshot of Muso's own app or site (issuer Muso" + (", Muso UI text)" if t else ")")
    if t and doc_type in SCREENISH and _MUSO_UI.search(t) and not has_credit:
        return SYS_001, "a screenshot of Muso's own app or site (Muso UI text)"
    # Below this line no Muso-issued artifact: a document carrying an extracted credit is NEVER junk (QA #1472).
    # (Above, a Muso-issued screenshot stays SYS-001 with credits on it - Fable 092/093: our own record.)
    if has_credit:
        return None, "not junk: the document carries an extracted credit"
    if t and _LEASE.search(t) and doc_type in ("contract", "other", "receipt", "invoice", None):
        return "lease_licence_template", "a beat lease / licence template with no credit on it"
    # A DAW application screen, read from the TEXT only (Fable 090 sample #16: a Dropbox listing of a track's
    # session files carries H3 kind daw_session but can be evidence of work - never junk on the kind alone).
    ui = {m.lower() for m in _DAW_UI.findall(t)} | ({"menu bar", "menu"} if t and _DAW_MENU.search(t) else set()) \
        if t else set()
    if t and _DAW.search(t) and len(ui) >= DAW_UI_MIN and not _PROSE.search(t) and not _FILE_HOST.search(t) \
            and not has_credit and doc_type in ("other", "dashboard_screenshot", None):
        return "daw_instrument_photo", "a DAW application screen with no credit text"
    # No camera-photo rule (QA #1472): camera metadata + sparse OCR is not a positive gear/studio
    # identification - a photographed split sheet reads the same. Only a DAW application screen counts.
    return None, "not junk" + ("" if text is not None else " by the stored-data rules (text not checked)")


SMALL_FILING = 5      # a filing with at most this many open requests is tied to each of them


def junk_list(rows: list[dict[str, Any]], titles: dict[str, str] | None = None,
              open_ids: set[str] | None = None) -> dict[str, Any]:
    """`rows`: one per filed document {intake_id, user_id, paid, candidates [request ids], artifact (kind or
    None), why, text_checked, named (folded track titles the document names)}. `titles`: request id -> its
    folded track title. Returns the purge list (junk documents, per user with counts, SYS-001 apart) and the
    decline proposal: the requests whose EVERY filed document is junk AND that are TIED to a junk document -
    it names the request's track, or its filing had <= SMALL_FILING open requests. A filing's candidates are
    ALL the account's open requests when it arrived, so without the tie one Muso screenshot would decline an
    account's every request (10-28: 162 of 198 were tied only that way). Untied requests are listed as held."""
    titles = titles or {}
    # `open_ids`: the requests that are open and not deleted NOW (stage2.requests at report time, QA #1472) - a
    # request approved or closed after the junk document was filed is never proposed. None = not checked.
    users: dict[int, dict[str, Any]] = {}
    by_request: dict[str, list[dict[str, Any]]] = {}
    for r in rows:
        for rid in r.get("candidates") or []:
            by_request.setdefault(rid, []).append(r)
        if not r.get("artifact"):
            continue
        u = users.setdefault(int(r["user_id"]), {"user_id": int(r["user_id"]), "paid": bool(r.get("paid")),
                                                 "counts": {}, "documents": []})
        u["counts"][r["artifact"]] = u["counts"].get(r["artifact"], 0) + 1
        u["documents"].append({k: r.get(k) for k in ("intake_id", "artifact", "why", "text_checked")})
    decline, held, closed = [], [], []
    for rid, docs in sorted(by_request.items()):
        if docs and all(d.get("artifact") for d in docs) and open_ids is not None and rid not in open_ids:
            closed.append(rid)
            continue
        if docs and all(d.get("artifact") for d in docs):
            t = titles.get(rid)
            named = bool(t) and any(t in (d.get("named") or ()) for d in docs)
            small = any(len(d.get("candidates") or []) <= SMALL_FILING for d in docs)
            row = {"request_id": rid, "user_id": docs[0]["user_id"], "paid": bool(docs[0].get("paid")),
                   "documents": [d["intake_id"] for d in docs], "kinds": sorted({d["artifact"] for d in docs}),
                   "sys_001_only": all(d["artifact"] == SYS_001 for d in docs),
                   "link": "the document names this track" if named else
                   f"its filing had <= {SMALL_FILING} open requests" if small else None}
            (decline if row["link"] else held).append(row)
    totals: dict[str, int] = {}
    for r in rows:
        if r.get("artifact"):
            totals[r["artifact"]] = totals.get(r["artifact"], 0) + 1
    order = sorted(users.values(), key=lambda u: (not u["paid"], -sum(u["counts"].values()), u["user_id"]))
    # every filed document, junk or not, read or not, with its stated kind (QA #1472: reviewers audit coverage
    # before confirming a purge or decline)
    every = [{"intake_id": r.get("intake_id"), "user_id": r.get("user_id"), "artifact": r.get("artifact"),
              "why": r.get("why"), "text_checked": bool(r.get("text_checked")), "read": bool(r.get("read", True)),
              "candidates": len(r.get("candidates") or [])} for r in rows]
    return {"documents": len(rows), "document_rows": every, "junk_documents": sum(totals.values()), "by_kind": totals,
            "sys_001": totals.get(SYS_001, 0), "text_checked": sum(1 for r in rows if r.get("text_checked")),
            "users": order, "decline_requests": decline, "held_untied": held, "closed_since_filing": closed}


def filed_rows(store_db: Any, proof_db: Any, paid: frozenset[int] | set[int],
               version: str | None = None) -> list[dict[str, Any]]:
    """junk_list's input: one row per filed document (proof_intake) with its artifact kind from the reader's latest
    steps (or the stored-data rules when only an extract exists), `read`, and `named` (folded track titles the
    extraction names). `version`: count only that reader version's steps (the coded C3 close needs a read under the
    current reader; the junk-list report keeps every version). Read-only."""
    import json
    from .extract import _title_key
    sql = "SELECT proof_id, step, detail_json FROM dv_steps WHERE step IN ('artifact', 'extract', 'text')"
    args: tuple[Any, ...] = ()
    if version is not None:
        sql += " AND version = ?"
        args = (version,)
    latest: dict[tuple[str, str], dict[str, Any]] = {}
    for pid, step, det in store_db.execute(sql + " ORDER BY id", args):
        try:
            latest[(pid, step)] = json.loads(det or "{}")
        except ValueError:
            continue
    kinds = dict(proof_db.execute("SELECT proof_id, kind FROM fingerprints"))
    rows = []
    for iid, uid, sha, cands in proof_db.execute("SELECT intake_id, user_id, file_sha256, candidate_request_ids_json "
                                                 "FROM proof_intake ORDER BY intake_id"):
        try:
            cand = [str(c) for c in json.loads(cands or "[]")]
        except ValueError:
            cand = []
        art = latest.get((sha, "artifact"))
        if art is not None:
            kind, why, checked = art.get("artifact"), art.get("why"), bool(art.get("text_checked"))
        elif (sha, "extract") in latest:
            facts = (latest.get((sha, "text")) or {}).get("facts") or {}
            kind, why = classify(text=None, ex=latest[(sha, "extract")], facts=facts,
                                 kind=kinds.get(sha) or (latest.get((sha, "text")) or {}).get("kind"))
            checked = False
        else:
            kind, why, checked = None, "not read yet", False
        ex = latest.get((sha, "extract")) or {}
        named = sorted({_title_key(t.get("title")) for t in ex.get("tracks") or [] if t.get("title")} |
                       {_title_key(c.get("track")) for c in ex.get("credits") or [] if c.get("track")})
        rows.append({"intake_id": iid, "user_id": uid, "paid": uid in paid, "candidates": cand, "artifact": kind,
                     "why": why, "text_checked": checked, "read": (sha, "extract") in latest or art is not None,
                     "named": named})
    return rows
