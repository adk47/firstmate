"""Domain and person intelligence for a returned document (captain 2026-10-27 21:5xZ, SHADOW).

Captain: "fraud check their domain, name, look to see if these people really exist and if
they are being duped". Two checks, both read-only and run on node-8, nothing sent:

  xc_domain_intel  every domain on the document (the sender's and every other address):
                   RDAP registration age, look-alike/typosquat of the issuer's independently
                   found official domain, MX / SPF / DMARC present, a free-mail address
                   claiming to speak for a company.
  xc_people        every person the document names (signatory, credited people,
                   counterparties): is the same name found in Muso's credits graph (the
                   catalog profiles, which carry the Spotify/Tidal/MLC identities), in the
                   claimed track's Spotify/Tidal credits, in MusicBrainz (exact artist name),
                   or on the issuer's official site (signatory)? A name found nowhere is
                   flagged: it does not prove anything on its own (most collaborators have no
                   public footprint), so it is evidence for a human, never an outcome.

Statuses follow crosscheck: positive | soft | weak | unknown | skipped | error. xc_domain_intel
is `soft` (blocks `verified`, never forges) on a domain registered < 180 days ago, a typosquat
of the official domain, or a company issuer writing from free-mail; xc_people is `weak` when a
named person exists nowhere (a flag, never blocks).
"""

from __future__ import annotations

import json
import re
import urllib.error
from datetime import datetime, timezone
from typing import Any, Callable, Iterable

from credit_review.judge import registrable_domain
from credit_review.roles import fold, names_match

from . import crosscheck as xc

YOUNG_DOMAIN_DAYS = 180
MAX_PEOPLE = 15               # per document; credits pages can list dozens
COMPANY_ISSUERS = ("label", "distributor", "publisher", "studio", "pro", "management")

NameIndex = Callable[[list[str]], "set[str]"]   # folded names -> the subset Muso's credits graph knows


# -- domains ------------------------------------------------------------------------
def levenshtein(a: str, b: str) -> int:
    if a == b:
        return 0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def _label(domain: str) -> str:
    return registrable_domain(domain).split(".")[0]


def typosquat(domain: str, official: Iterable[str]) -> str | None:
    """The official domain this one imitates, or None: a different registrable domain whose
    first label is within edit distance 2 of an official one's (bluefem.com vs bluefern.com),
    or the official label embedded with extra words (bluefern-records.net)."""
    dom = registrable_domain(domain)
    for off in official:
        o = registrable_domain(off)
        if not o or dom == o:
            continue
        a, b = _label(dom), _label(o)
        if len(b) >= 4 and (levenshtein(a, b) <= 2 or (b in a and a != b)):
            return o
    return None


def registered_at(net: xc.Net, domain: str) -> datetime | None:
    try:
        data = net.json(f"https://rdap.org/domain/{registrable_domain(domain)}")
    except (urllib.error.URLError, ValueError, OSError):
        return None
    for ev in (data or {}).get("events") or []:
        if ev.get("eventAction") == "registration":
            try:
                return datetime.fromisoformat(str(ev.get("eventDate")).replace("Z", "+00:00"))
            except ValueError:
                return None
    return None


def mail_auth(net: xc.Net, domain: str) -> dict[str, bool | None]:
    """SPF and DMARC published? None = could not be read."""
    out: dict[str, bool | None] = {"spf": None, "dmarc": None}
    for key, name, pat in (("spf", domain, r"v=spf1"), ("dmarc", f"_dmarc.{domain}", r"v=DMARC1")):
        recs = net.txt(name)
        if recs is not None:
            out[key] = any(re.search(pat, r, re.I) for r in recs)
    return out


def domain_intel(net: xc.Net, sender: str | None, others: Iterable[str], issuer: str | None,
                 issuer_type: str | None, official: list[str], now: datetime | None = None,
                 uncertain: Iterable[str] = ()) -> xc.Check:
    """The SENDER's domain (the address the document was sent from, extracted with confidence)
    gets every issuer check: free-mail for a company issuer, look-alike, registration age,
    NXDOMAIN, MX/SPF/DMARC. Every OTHER address on the document (counterparties, the claimant,
    cc lines) is attributed to nobody, so it is checked only for impersonation - a look-alike of
    the issuer's official domain - and recorded; a claimant's gmail on a label letter is not the
    label writing from free-mail (QA #1412). All domains are checked: no truncation.
    `uncertain`: the sender domain the extractor read with LOW confidence (< 0.6). It may be a
    misread of the real sender (bluefem.com for bluefern.com), so it is recorded and NEVER flags,
    wherever else it appears on the document (QA #1412, second pass)."""
    now = now or datetime.now(timezone.utc)
    snd = registrable_domain(sender) if sender else None
    unsure = {registrable_domain(x) for x in uncertain if x} - {snd}
    rest = [d for d in dict.fromkeys(registrable_domain(x) for x in others if x) if d and d != snd and d not in unsure]
    if not snd and not rest and not unsure:
        return xc.Check("xc_domain_intel", xc.SKIPPED, {"why": "no email address on the document"})
    per, flags = [], []
    for d in sorted(d for d in unsure if d):
        per.append({"domain": d, "role": "uncertain sender (confidence < 0.6): recorded, never a flag",
                    "official": d in official, "imitates": typosquat(d, official)})
    for d in rest:
        row: dict[str, Any] = {"domain": d, "role": "other address", "official": d in official}
        sq = typosquat(d, official) if d not in xc.FREEMAIL else None
        if sq:
            row["imitates"] = sq
            flags.append(f"{d}: look-alike of the official {sq} (an address on the document)")
        per.append(row)
    for d in [snd] if snd else []:
        row: dict[str, Any] = {"domain": d, "role": "sender", "official": d in official}
        if d in xc.FREEMAIL:
            row["freemail"] = True
            if issuer and issuer_type in COMPANY_ISSUERS:
                flags.append(f"{d}: free-mail address for a {issuer_type} ({issuer})")
            per.append(row)
            continue
        sq = typosquat(d, official)
        if sq:
            row["imitates"] = sq
            flags.append(f"{d}: look-alike of the official {sq}")
        reg = registered_at(net, d)
        row["registered"] = reg.date().isoformat() if reg else None
        if reg and (now - reg).days < YOUNG_DOMAIN_DAYS:
            flags.append(f"{d}: registered {(now - reg).days} days ago")
        row["mx"] = net.mx(d)
        row.update(mail_auth(net, d))
        if row["mx"] == "nxdomain":
            flags.append(f"{d}: does not exist")
        elif row.get("spf") is False and row.get("dmarc") is False and not row["official"]:
            row["no_mail_auth"] = True            # recorded; common for small senders, not a flag alone
        per.append(row)
    detail = {"domains": per, "flags": flags, "issuer": issuer, "official": official}
    if flags:
        return xc.Check("xc_domain_intel", xc.SOFT, detail)
    if any(r.get("official") and r.get("role") == "sender" for r in per):
        return xc.Check("xc_domain_intel", xc.POSITIVE, detail)
    return xc.Check("xc_domain_intel", xc.UNKNOWN, detail)


# -- people -------------------------------------------------------------------------
ORG_WORDS = frozenset({"srl", "llc", "inc", "ltd", "limited", "gmbh", "sa", "sas", "bv", "ab", "llp", "co", "corp",
                       "publishing", "publisher", "music", "musica", "musique", "records", "recordings", "media",
                       "services", "entertainment", "productions", "production", "group", "label", "editions",
                       "edition", "songs", "rights", "administration", "company", "studio", "studios"})


def person_name(raw: str) -> str | None:
    """A person's name as people write it, or None for an organisation. A PRO-style
    "Surname, Firstname" (one comma) is turned into "Firstname Surname"."""
    name = re.sub(r"\s+", " ", (raw or "").strip())
    if set(fold(name).split()) & ORG_WORDS:
        return None
    if name.count(",") == 1:
        last, first = (x.strip() for x in name.split(","))
        if last and first:
            name = f"{first} {last}"
    return name if len(fold(name)) >= 3 else None


def people_of(ex: Any) -> list[dict[str, str]]:
    """Every person the document names (organisations dropped), signatory first,
    deduplicated by folded name."""
    out: list[dict[str, str]] = []
    seen: set[str] = set()
    cands = []
    sig = (ex.signatory or {}).get("name")
    if sig and (ex.signatory or {}).get("confidence", 0) >= 0.6:
        cands.append((sig, "signatory"))
    cands += [(c.get("person") or "", c.get("role") or "") for c in ex.credits or [] if c.get("confidence", 0) >= 0.6]
    for raw, role in cands:
        name = person_name(raw)
        if name and fold(name) not in seen:
            seen.add(fold(name))
            out.append({"name": name, "role": role})
    return out[:MAX_PEOPLE]


def people_check(net: xc.Net, people: list[dict[str, str]], *, graph: NameIndex | None,
                 track_credits: list[dict[str, Any]] | None, issuer_site_names: Iterable[str] = (),
                 musicbrainz: bool = True) -> xc.Check:
    """`issuer_site_names`: folded names xc_signatory found on the issuer's official site this run
    (the runner passes the signatory when xc_signatory is positive; no second fetch)."""
    on_site = {fold(n) for n in issuer_site_names if n}
    if not people:
        return xc.Check("xc_people", xc.SKIPPED, {"why": "the document names nobody"})
    known: set[str] = set()
    graph_error = None
    if graph is not None:
        try:
            known = graph([fold(p["name"]) for p in people])
        except Exception as exc:  # noqa: BLE001 - an unreadable graph is recorded, never a pass
            graph_error = f"{type(exc).__name__}"[:80]
    dsp_names = [str((c.get("profile") or {}).get("name") or "") for c in (track_credits or [])
                 if str((c.get("profile") or {}).get("source") or "").lower() in xc.LIVE_DSPS]
    rows, nowhere = [], []
    for p in people:
        found = []
        if fold(p["name"]) in known:
            found.append("muso_credits_graph")
        if any(names_match(p["name"], n) for n in dsp_names if n):
            found.append("track_spotify_tidal")
        if fold(p["name"]) in on_site:
            found.append("issuer_site")
        if not found and musicbrainz:
            try:
                data = net.mb("artist", {"query": f'artist:"{p["name"][:80]}"', "limit": "3"})
                if any(int(a.get("score") or 0) >= 100 and fold(a.get("name") or "") == fold(p["name"])
                       for a in data.get("artists") or []):
                    found.append("musicbrainz")
            except Exception:  # noqa: BLE001 - one lookup failing never stops the rest
                pass
        rows.append({**p, "found_in": found})
        if not found:
            nowhere.append(p["name"])
    detail = {"people": rows, "found_nowhere": nowhere, "graph_error": graph_error}
    if graph_error and not any(r["found_in"] for r in rows):
        return xc.Check("xc_people", xc.ERROR, detail)
    return xc.Check("xc_people", xc.WEAK if nowhere else xc.POSITIVE, detail)


SQL_FOLD = ("trim(regexp_replace(lower(regexp_replace(normalize(name, NFKD), '\\p{M}', '')), "
            "'[^0-9a-z]+', ' '))")


def trino_name_index(trino: Callable[[str], str], batch: int = 200) -> NameIndex:
    """Folded names -> those present as a catalog profile name (read-only SELECT, one query per
    `batch` names). Names are matched on lower(name); the folded comparison happens here."""
    import csv
    import io

    def index(names: list[str]) -> set[str]:
        want = sorted({n for n in names if n})
        out: set[str] = set()
        for i in range(0, len(want), batch):
            part = want[i:i + batch]
            # Fold IN SQL exactly as roles.fold does (NFKD, marks dropped, non-alphanumerics -> one
            # space, lower, trimmed), so 'José López' / "O'Neil" reach the Python comparison (QA #1412).
            lits = ",".join("'" + n.replace("'", "''") + "'" for n in part)
            sql = (f"SELECT DISTINCT name FROM postgresql_catalog.public.catalog_profile WHERE {SQL_FOLD} IN ({lits})")
            for r in csv.reader(io.StringIO(trino(sql))):
                if r and fold(r[0]) in part:
                    out.add(fold(r[0]))
        return out
    return index


def as_json(c: xc.Check) -> str:
    return json.dumps(c.as_dict(), default=str, ensure_ascii=False)
