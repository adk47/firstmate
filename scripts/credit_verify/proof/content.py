"""F5 content cross-checks and F3c / F5e portal-screenshot checks.

Works on the text the file showed (PDF text layer or OCR). With a linked
claim (ClaimContext) it compares the document with the claimed recording,
the claimant and our catalog stats; without one (Intercom replay before core
C1b links proofs to requests) it only extracts entities for the fingerprint.

Mismatch signals carry a plain reason the claimant can act on ("the ISRC in
your document is for a different recording"). Real-data calibration (§8):
split sheets often hold several songs, so shares are judged per song and only
an unambiguous single-song sheet whose shares cannot add up is a mismatch.
"""

from __future__ import annotations

import hashlib
import re
from typing import Any

from credit_review.roles import family_of, fold, names_match

from . import ocr
from .signals import INFO, MISMATCH, POSITIVE, SOFT, ClaimContext, Evidence, Extracted, Signal

TOOL = "credit_verify.content"

ISRC = re.compile(r"\b([A-Z]{2})-?([A-Z0-9]{3})-?(\d{2})-?(\d{5})\b")
ISWC = re.compile(r"\bT-?(\d{3})\.?(\d{3})\.?(\d{3})-?(\d)\b")
UPC_LABELLED = re.compile(r"\b(?:UPC|EAN|barcode)\b[^0-9]{0,12}(\d{12,13})\b", re.I)
PERCENT = re.compile(r"(?<![\d.])(\d{1,3}(?:[.,]\d{1,2})?)\s?%")
TITLE_LINE = re.compile(r"^\s*(?:song|track|work|composition)?\s*(?:title|name)\s*[:\-]\s*(.+)$", re.I | re.M)

KINDS = (
    ("split_sheet", re.compile(r"split\s*sheet|songwriter split|writer'?s? share|ownership split|% of (the )?composition|split agreement", re.I)),
    ("contract", re.compile(r"\bagreement\b|\bcontract\b|hereinafter|whereas|party of the (first|second) part|in witness whereof", re.I)),
    ("invoice", re.compile(r"\binvoice\b|amount due|bill to|payment terms|subtotal", re.I)),
    ("letter_of_direction", re.compile(r"letter of direction|\bLOD\b", re.I)),
    ("pro_portal", re.compile(r"\bASCAP\b|\bBMI\b|\bSESAC\b|\bPRS\b|\bThe MLC\b|Songview|\bSOCAN\b|\bGEMA\b|\bSACEM\b|\bIPI\b", re.I)),
    ("distributor_portal", re.compile(r"DistroKid|TuneCore|CD ?Baby|Amuse|UnitedMasters|Ditto|Symphonic|AWAL|Stem\b", re.I)),
    ("dsp_for_artists", re.compile(r"Spotify for Artists|Apple Music for Artists|Artist Home|Amazon Music for Artists|"
                                   r"YouTube Studio", re.I)),
    ("daw_session", re.compile(r"Pro Tools|Logic Pro|Ableton|FL Studio|Cubase|Studio One|\.ptx\b|\.logicx\b|\.als\b", re.I)),
    ("catalog_page", re.compile(r"Discogs|AllMusic|Genius|MusicBrainz|TIDAL|Credits", re.I)),
)
DOCUMENT_KINDS = ("split_sheet", "contract", "invoice", "letter_of_direction")
PUBLIC_KINDS = ("pro_portal", "catalog_page")

# F3c: anchor words an authentic screenshot of each portal shows.
PORTALS = {
    "distrokid": ("DistroKid", ("Upload", "My Music", "Stats", "Splits", "Bank", "Upgrade")),
    "tunecore": ("TuneCore", ("Releases", "Money", "Publishing", "Dashboard", "Store")),
    "cdbaby": ("CD Baby", ("Dashboard", "Accounting", "Releases", "Payments")),
    "spotify_for_artists": ("Spotify for Artists", ("Home", "Music", "Audience", "Profile", "Listeners", "Streams")),
    "apple_music_for_artists": ("Apple Music for Artists", ("Plays", "Listeners", "Shazams", "Overview")),
    "tidal_artist_home": ("Artist Home", ("TIDAL", "Streams", "Tracks")),
    "ascap": ("ASCAP", ("Works", "Member", "Writer", "Share")),
    "bmi": ("BMI", ("Works", "Songwriter", "Catalog", "Share")),
    "the_mlc": ("The MLC", ("Works", "Shares", "Writers", "Publishers")),
}
DSP_PORTALS = ("spotify_for_artists", "apple_music_for_artists", "tidal_artist_home")
# F5e: which totals a dashboard shows. An artist-level view (Spotify for
# Artists Home / Audience, Apple Music for Artists Overview) shows the
# artist's numbers; a song/track page shows the track's. A screenshot showing
# both kinds of anchor, or neither, has no known scope and is not compared.
DSP_VIEWS = {
    "spotify_for_artists": {"artist": ("Home", "Audience"), "track": ("Song", "Track")},
    "apple_music_for_artists": {"artist": ("Overview",), "track": ("Song", "Track")},
    "tidal_artist_home": {"artist": (), "track": ("Song", "Track")},
}

# F2: Title-Case phrases made only of these words are form headings ("Song
# Title", "Writer Name", "Effective Date"), not names, so they are left out of
# the name hashes a template shares with every copy of itself.
FORM_WORDS = frozenset("""
a an and or of the this that these by for to in on at with from all each any per please list below above
song songs title titles track tracks work works composition compositions recording recordings master release
writer writers songwriter songwriters composer composers lyricist lyricists author authors producer producers
artist artists featured primary performer performers label record records publisher publishers publishing
administrator admin copyright owner owners ownership company name names full legal print printed
effective date dated signature signatures signed sign witness whereof party parties agreement agreements split
splits sheet share shares percentage percent total notes terms term territory schedule exhibit section clause
address email phone telephone city state country zip postal code number id tax social security
ipi cae isrc iswc upc pro society performing rights organization organisation mechanical collection
contact page between hereinafter start end new
""".split())

ROLE_WORDS = re.compile(
    r"\b(?:(?P<exec_producer>executive\s+produc(?:ers?|ed\s+by))"
    r"|(?P<master>(?:re-?)?master(?:ing(?:\s+engineers?)?|ed\s+by))"
    r"|(?P<mix>mix(?:ing)?\s+engineers?|mixers?|mixing|mixed\s+by)"
    r"|(?P<producer>co-?producers?|producers?|produced\s+by|production)"
    r"|(?P<writer>song\s?writers?|writers?|written\s+by|composers?|composed\s+by|lyricists?|lyrics\s+by|authors?)"
    r"|(?P<engineer>(?:recording\s+)?engineers?|engineered\s+by|recorded\s+by)"
    r"|(?P<arranger>arrangers?|arranged\s+by)"
    r"|(?P<programming>programmers?|programming|programmed\s+by))\b", re.I)
ROLE_COMPARED_AS = {"immersive_mix": "mix", "immersive_master": "master", "remaster": "master"}
DETECTABLE_ROLES = frozenset(ROLE_WORDS.groupindex)
NO_MATCH = "whole document, no match found"


def iswc_ok(m: re.Match) -> bool:
    digits = "".join(m.groups()[:3])
    total = 1 + sum((i + 1) * int(d) for i, d in enumerate(digits))
    return (10 - total % 10) % 10 == int(m.group(4))


def ean_ok(code: str) -> bool:
    code = code.zfill(13)
    s = sum(int(d) * (3 if i % 2 else 1) for i, d in enumerate(code[:12]))
    return (10 - s % 10) % 10 == int(code[12])


def classify_kind(text: str) -> str:
    scores = {k: len(rx.findall(text)) for k, rx in KINDS}
    best = max(scores.items(), key=lambda kv: kv[1])
    return best[0] if best[1] else "unknown"


FEATURING = re.compile(r"\s+(?:feat\.?|ft\.?|featuring)\s.*$", re.I)
WITH = re.compile(r"\s+with\s.*$", re.I)


def _title_key(t: str) -> str:
    t = re.sub(r"\s*[\(\[].*?[\)\]]", "", t or "")
    t = re.split(r"\s+-\s+", t)[0]
    t = FEATURING.sub("", t)
    without = WITH.sub("", t)
    return fold(without if len(fold(without).split()) >= 2 else t)


def title_in(text_folded: str, title: str) -> bool:
    key = _title_key(title)
    if len(key) < 3:
        return False
    if f" {key} " in f" {text_folded} ":
        return True
    toks = key.split()
    words = set(text_folded.split())
    return len(toks) >= 2 and sum(t in words for t in toks) / len(toks) >= 0.9


def matched_name(text: str, names: list[str]) -> tuple[str, str] | None:
    """(the name, the words of the text that match it) for the first of
    `names` the text shows as whole words, in any order."""
    folded = fold(text)
    tokens = folded.split()
    for n in names:
        key = fold(n)
        if not key:
            continue
        if len(key) >= 4 and f" {key} " in f" {folded} ":
            return n, n
        k = len(key.split())
        if k >= 2:
            for i in range(len(tokens) - k + 1):
                for window in (" ".join(tokens[i:i + k + 1]), " ".join(tokens[i:i + k])):
                    if names_match(window, n):
                        return n, window
    return None


def name_in(text: str, names: list[str]) -> str | None:
    """The words of the text that match one of `names`, if any."""
    m = matched_name(text, names)
    return m[1] if m else None


def name_hash(name: str) -> str:
    """Hash of a name with its words folded and sorted ("Alpha, Ann" ==
    "Ann Alpha"), so the name itself is never stored."""
    return hashlib.sha256(" ".join(sorted(fold(name).split())).encode()).hexdigest()[:16]


NAME_NOISE = frozenset("""
by produced producer producers production written writer writers songwriter songwriters composed composer composers
lyrics lyricist lyricists mixed mixer mixing mastered mastering engineer engineered arranged arranger programmed
programming feat featuring ft and with credits credit share shares split ipi cae
""".split())
NAME_SEPARATORS = re.compile(r"[,;:/|&\u2022\u00b7\t]|\s{2,}")
NON_COMMA_SEPARATORS = re.compile(r"[;:/|&\u2022\u00b7\t]|\s{2,}")


def _noise(token: str, keep: set[str] = frozenset()) -> bool:
    return token in NAME_NOISE or (any(ch.isdigit() for ch in token) and token not in keep)


def credited_name(text: str, name: str) -> str:
    """The credited name on the page that `name` matched, never the
    account's own spelling of it: the run of name words that holds all of
    the name's words, within one line and one list item (split at commas,
    '&', 'and', ';', '/'), without role words, numbers and IPI codes
    (digits stay when they are part of the name: 6LACK, 2Pac). "By Mike
    Dean", "Mike Dean Produced" and "Dean" all land on the "mike dean" of
    "Produced By Mike Dean". When several runs hold the name ("Bob Beta"
    beside "Publisher: Bob Beta Music"), the bare one, contained in all the
    others, is the credited name. A surname-first name split by one comma
    ("Alpha, Ann") counts as one run when it is one of the fixed pairs of a
    comma list read two items at a time ("Alpha, Ann, Beta, Bob" is "Alpha,
    Ann" and "Beta, Bob", never "Ann, Beta"; items with no name word, such
    as "Writers" or "2024", are dropped first; an odd item count has no pairs)
    and the pair holds exactly the name's words. '' when nothing holds the
    name ("Mike West" across "Kanye West, Mike Dean"), or when no run is
    contained in all the others ("Mike" in "Mike Will, Mike Dean"): the name
    then identifies nobody."""
    want = set(fold(name).split())
    core = {t for t in want if not _noise(t, want)}
    if not core:
        return ""
    runs: set[frozenset[str]] = set()
    for line in text.splitlines():
        for part in NAME_SEPARATORS.split(line):
            toks = fold(part).split()
            i = 0
            while i < len(toks):
                if _noise(toks[i], want):
                    i += 1
                    continue
                j = i
                while j < len(toks) and not _noise(toks[j], want):
                    j += 1
                if core <= set(toks[i:j]):
                    runs.add(frozenset(toks[i:j]))
                i = j
    if not runs:
        for line in text.splitlines():
            for segment in NON_COMMA_SEPARATORS.split(line):
                words = ({t for t in fold(item).split() if not _noise(t, want)} for item in segment.split(","))
                items = [w for w in words if w]   # a role word or number is not a pair member
                if len(items) % 2:
                    continue
                if any(left | right == core for left, right in zip(items[::2], items[1::2])):
                    return " ".join(sorted(core))
        return ""
    bare = [r for r in runs if all(r <= other for other in runs)]
    return " ".join(sorted(bare[0])) if len(bare) == 1 else ""


def split_blocks(text: str) -> list[tuple[list[float], str]]:
    """Percentages per song block, with the block's first share as written.
    A block starts at a title line or an ISRC."""
    starts = sorted({m.start() for m in TITLE_LINE.finditer(text)} | {m.start() for m in ISRC.finditer(text)})
    if len(starts) <= 1:
        bounds = [(0, len(text))]
    else:
        bounds = [(a, b) for a, b in zip(starts, starts[1:] + [len(text)])]
        if starts[0] > 0:
            bounds[0] = (0, bounds[0][1])
    out = []
    for a, b in bounds:
        found = [(float(m.group(1).replace(",", ".")), m.group(0)) for m in PERCENT.finditer(text[a:b])]
        found = [(v, raw) for v, raw in found if 0 < v <= 100]
        if found:
            out.append(([v for v, _ in found], found[0][1]))
    return out


def entities(text: str) -> dict[str, Any]:
    isrcs = sorted({"".join(m.groups()) for m in ISRC.finditer(text or "")})
    iswcs = sorted({"T" + "".join(m.groups()) for m in ISWC.finditer(text or "")})
    pcts = sorted(float(m.group(1).replace(",", ".")) for m in PERCENT.finditer(text or ""))
    caps = [fold(c) for c in re.findall(r"\b([A-Z][a-z]+(?:[ \t]+[A-Z][a-z]+)+)\b", text or "")]
    names = {c for c in caps if not set(c.split()) <= FORM_WORDS}
    name_h = sorted({hashlib.sha256(c.encode()).hexdigest()[:12] for c in names})[:40]
    roles = sorted({m.lastgroup for m in ROLE_WORDS.finditer(text or "") if m.lastgroup})
    return {"isrcs": isrcs[:20], "iswcs": iswcs[:20], "percent_sig": ",".join(f"{p:g}" for p in pcts[:20]),
            "name_hashes": name_h, "roles": roles}


def role_listed(document_roles: Any, claimed_families: Any) -> bool | None:
    """Whether the document's role words include a role family the claimant
    claims; None when that cannot be told (no role words in the document, or
    no claimed family the role words can express - performer, artist,
    assistant, A&R, ...)."""
    norm = lambda fams: {ROLE_COMPARED_AS.get(f, f) for f in fams or ()}  # noqa: E731
    listed, claimed = norm(document_roles), norm(claimed_families) & DETECTABLE_ROLES
    if not listed or not claimed:
        return None
    return bool(listed & claimed)


def role_signals(kind: str, document_roles: Any, claimed_roles: list[str], named: bool | None,
                 path: str) -> list[Signal]:
    """The claimed role against the document, for ONE claim (one role):
    expressible but not listed on a document that names the claimant -> soft;
    a role the document cannot show -> info, which caps the verdict at
    PLAUSIBLE."""
    claimed = {family_of(r) for r in claimed_roles}
    listed = role_listed(document_roles, claimed)
    ev = Evidence(file=path, tool=TOOL, excerpt=NO_MATCH)
    if listed is False and named and kind in DOCUMENT_KINDS:
        return [Signal("F5b", "claimed_role_not_listed", SOFT, value={"claimed": sorted(claimed)},
                       reason="The document doesn't list the role you claimed.", evidence=ev)]
    if listed is not True:
        return [Signal("F5b", "claimed_role_not_expressible", INFO,
                       value={"claimed": sorted(claimed), "role_words": sorted(document_roles or [])},
                       reason="The document can't show the role you claimed.", evidence=ev)]
    return []


def portal(text: str) -> tuple[str | None, int, int]:
    best = (None, 0, 0)
    for key, (brand, anchors) in PORTALS.items():
        if brand.lower() not in text.lower():
            continue
        hits = sum(1 for a in anchors if re.search(r"\b" + re.escape(a) + r"\b", text, re.I))
        if hits >= best[1]:
            best = (key, hits, len(anchors))
    return best


def dsp_scope(text: str, portal_key: str) -> str | None:
    """'artist' or 'track' when the view's anchor words say which totals the
    dashboard shows; None when they don't (or say both)."""
    views = DSP_VIEWS.get(portal_key) or {}
    has = {scope: any(re.search(r"\b" + re.escape(a) + r"\b", text, re.I) for a in words)
           for scope, words in views.items()}
    if has.get("artist") and not has.get("track"):
        return "artist"
    if has.get("track") and not has.get("artist"):
        return "track"
    return None


def _numbers_near(text: str, label: str) -> list[tuple[int, str]]:
    out = []
    for m in re.finditer(label, text, re.I):
        window = text[max(0, m.start() - 40):m.end() + 40]
        for n in re.findall(r"\b\d{1,3}(?:,\d{3})+\b|\b\d{4,12}\b", window):
            out.append((int(n.replace(",", "")), n))
    return out


def _key(s: str) -> str:
    return re.sub(r"[^0-9a-z]", "", fold(s))


def locate(ext: Extracted, needle: str) -> dict[str, Any]:
    """Page and region of the first run of words (PDF text layer or OCR boxes)
    that spells `needle`; {} when the words carry no boxes or don't spell it."""
    key = _key(needle)
    if len(key) < 2:
        return {}
    words = ext.words
    keys = [_key(str(w.get("text") or "")) for w in words]
    for i, w in enumerate(words):
        if not keys[i]:
            continue
        acc, boxes = "", []
        for j in range(i, min(i + 12, len(words))):
            if words[j].get("page") != w.get("page"):
                break
            acc += keys[j]
            boxes.append(words[j]["box"])
            at = acc.find(key)
            if at >= len(keys[i]):
                break
            if at >= 0:
                return {"page": w.get("page"),
                        "region": [round(min(b[0] for b in boxes), 1), round(min(b[1] for b in boxes), 1),
                                   round(max(b[2] for b in boxes), 1), round(max(b[3] for b in boxes), 1)]}
            if len(acc) - len(keys[i]) >= len(key):
                break
    return {}


def analyze(ext: Extracted, ctx: ClaimContext, path: str) -> tuple[list[Signal], dict[str, Any]]:
    text = ext.text

    def ev(needle: str | None = None, **kw: Any) -> Evidence:
        return Evidence(file=path, tool=TOOL, **{**(locate(ext, needle) if needle else {}), **kw})

    sig: list[Signal] = []
    ext.kind = classify_kind(text)
    ents = entities(text)
    sig.append(Signal("F5a", "document_kind", INFO, value={"kind": ext.kind, "text_source": ext.text_source,
                                                         "chars": len(text)}, evidence=ev()))
    for m in ISWC.finditer(text):
        if not iswc_ok(m):
            sig.append(Signal("F5a", "iswc_check_digit_invalid", SOFT, value=m.group(0),
                              evidence=ev(m.group(0), excerpt="ISWC")))
            break
    for m in UPC_LABELLED.finditer(text):
        if not ean_ok(m.group(1)):
            sig.append(Signal("F5a", "upc_check_digit_invalid", SOFT, value=m.group(1),
                              evidence=ev(m.group(1), excerpt="UPC")))
            break
    p_key, p_hits, p_n = portal(text)
    if p_key:
        sig.append(Signal("F3c", "portal_identified", INFO, value={"portal": p_key, "anchors": f"{p_hits}/{p_n}"},
                          evidence=ev()))
        if p_hits < 2:
            # Calibration pending (pf-1): a cropped screenshot also lacks anchors.
            sig.append(Signal("F3c", "portal_template_incomplete", INFO, value={"portal": p_key, "anchors": p_hits},
                              evidence=ev()))

    if not ctx.linked:
        return sig, ents

    folded = fold(text)
    # A PDF's text layer can say what the rendered page does not show (text
    # under an opaque box). What supports the claim must also be on the
    # rendered page (OCR); otherwise it caps the verdict at PLAUSIBLE.
    shown = ocr.words_to_text(ext.ocr_words) if ext.text_source == "pdf_text" else None
    unseen: list[str] = []
    written: dict[str, str] = {}
    for m in ISRC.finditer(text):
        written.setdefault("".join(m.groups()), m.group(0))
    doc_isrcs = set(written)
    want = {re.sub(r"[^A-Z0-9]", "", i.upper()) for i in ctx.isrcs}
    t_found = bool(ctx.track_title) and title_in(folded, ctx.track_title or "")
    checkable = bool(folded) and (len(_title_key(ctx.track_title or "")) >= 3 or bool(want))
    ext.track_listed = (t_found or bool(doc_isrcs & want)) if checkable else None
    if doc_isrcs & want:
        hit = sorted(doc_isrcs & want)[0]
        if shown is not None and hit not in {"".join(m.groups()) for m in ISRC.finditer(shown)}:
            unseen.append("isrc")
        sig.append(Signal("F5a", "isrc_matches_claim", POSITIVE, value=hit, evidence=ev(written[hit], excerpt="ISRC")))
    elif doc_isrcs and want:
        other = sorted(doc_isrcs)[0]
        sig.append(Signal("F5a", "isrc_other_recording", MISMATCH, value={"in_document": len(doc_isrcs)},
                          reason="The ISRC in your document is for a different recording.",
                          evidence=ev(written[other], excerpt=f"ISRC; {NO_MATCH}")))
    if t_found:
        if shown is not None and not title_in(fold(shown), ctx.track_title or ""):
            unseen.append("title")
        sig.append(Signal("F5a", "title_matches_claim", POSITIVE, evidence=ev(_title_key(ctx.track_title or ""))))
    elif not (doc_isrcs & want) and ext.kind in DOCUMENT_KINDS:
        sig.append(Signal("F5a", "track_not_named", SOFT,
                          reason="The document doesn't name this track.", evidence=ev(excerpt=NO_MATCH)))

    if ext.kind in DOCUMENT_KINDS + PUBLIC_KINDS and (ctx.claimant_names or ctx.verified_names):
        verified = matched_name(text, ctx.verified_names)
        found = verified or matched_name(text, ctx.claimant_names)
        credited = credited_name(text, found[0]) if found else ""
        who = ({"name_h": name_hash(credited) if credited else None, "verified_identity": bool(verified)}
               if found else None)
        # Words that match the name but are no credited name on the page
        # ("Ann Beta" across "Alpha, Ann, Beta, Bob") identify nobody.
        if found and credited and (verified or ext.kind in DOCUMENT_KINDS):
            if shown is not None and not matched_name(shown, [found[0]]):
                unseen.append("claimant")
            sig.append(Signal("F5b", "claimant_named", POSITIVE, value=who, evidence=ev(found[1])))
        elif found:
            sig.append(Signal("F5b", "claimant_named_unverified", INFO, value=who,
                              reason=("A public page names you, but not under a verified identity." if credited
                                      else "The document doesn't show your name as one credited person."),
                              evidence=ev(found[1])))
        elif ext.kind in DOCUMENT_KINDS:
            sig.append(Signal("F5b", "claimant_not_named", MISMATCH,
                              reason="Your name doesn't appear in the document.", evidence=ev(excerpt=NO_MATCH)))
        else:
            sig.append(Signal("F5b", "claimant_not_found", INFO, evidence=ev(excerpt=NO_MATCH)))

    if unseen:
        sig.append(Signal("F4c", "claim_text_not_rendered", INFO, value={"fields": unseen},
                          reason="The page doesn't visibly show the details that match your claim.",
                          evidence=Evidence(file=path, tool=ocr.TOOL, excerpt=NO_MATCH)))

    if ext.kind == "split_sheet":
        blocks = [(round(sum(vals), 2), len(vals), first) for vals, first in split_blocks(text) if len(vals) >= 2]
        sig.append(Signal("F5c", "split_sums", INFO, value=[b[0] for b in blocks][:10], evidence=ev()))
        if len(blocks) == 1:
            s, n, first = blocks[0]
            if abs(s - 100) > 0.5 and not (s > 100 and abs(s / 100 - round(s / 100)) * 100 <= 0.5):
                sig.append(Signal("F5c", "split_shares_do_not_add_up", MISMATCH, value=s,
                                  reason=f"The shares on your split sheet add up to {s:g}%, not 100%.",
                                  evidence=ev(first, excerpt=f"split block of {n} shares")))

    if p_key in DSP_PORTALS:
        if ctx.track_artists and not name_in(text, ctx.track_artists):
            sig.append(Signal("F5e", "dsp_artist_not_track_artist", SOFT, value={"portal": p_key},
                              reason="The dashboard doesn't show an artist on this track.",
                              evidence=ev(excerpt=NO_MATCH)))
        shown = [(n, raw) for n, raw in _numbers_near(text, r"streams|plays") if n > 0]
        if shown:
            scope = dsp_scope(text, p_key)
            total = {"artist": ctx.artist_lifetime_streams, "track": ctx.lifetime_streams}.get(scope or "")
            top, raw = max(shown)
            if not total:
                sig.append(Signal("F5e", "dsp_number_scope_unknown", INFO,
                                  value={"portal": p_key, "scope": scope, "catalog_total_known": bool(total)},
                                  evidence=ev()))
            elif top > total * 1.15:
                sig.append(Signal("F5e", "dsp_numbers_exceed_catalog", MISMATCH,
                                  value={"shown_max": top, "catalog_lifetime": total, "scope": scope},
                                  reason=(f"The dashboard numbers are higher than "
                                          f"{'this artist' if scope == 'artist' else 'this track'}'s total streams."),
                                  evidence=ev(raw)))
    return sig, ents
