"""Step 3: independent cross-checks. Every source here is one the user does
not control, and nothing is taken from the document except the CLAIM to
check (who issued it, who signed it, which domain sent it):

  xc_dsp        the claimed role on the track in Muso's trusted raw credits
                (Spotify, Tidal, MLC, Jaxsta; credit_review.evidence
                .classify_roles): CONFIRMED -> positive; a one-person role
                (mix/master) credited to someone else -> contradicts.
                These are Muso's last catalog capture, read with one admin GET
                per track; a live re-capture is core-backend's DSP gate
                (#10765), not on prod yet.
  xc_isrc       MusicBrainz by ISRC (artist relationships: producer, mix,
                engineer, ...) and Deezer by ISRC (contributors, album label):
                the claimant in the role family -> positive. Community data:
                "others only" is recorded, never a contradiction.
  xc_label      the claimed issuer vs the release's label line (Deezer album
                label). A label that is not the release's label is soft doubt;
                a distributor or PRO issuer is not compared (their name is
                rarely the label line).
  xc_domain     the sender's domain vs the issuer's OFFICIAL domain, found
                independently (MusicBrainz label url-rels "official homepage",
                or the fixed list of distributor/PRO domains below), never the
                address on the document; free-mail; MX/NXDOMAIN. A domain that
                looks like the issuer but is not its official domain, or a
                domain that does not exist, is a contradiction (a fabricated
                sender).
  xc_signatory  the signatory's name on the issuer's official site (home,
                about, team, contact pages). Not found is unknown, never a
                contradiction.

Statuses: positive | contradicts | soft | weak | unknown | error | skipped.
Network calls are SSRF-guarded (credit_trust.websearch.http_get) and paced
for MusicBrainz (1 req/s, shared process-wide lock).
"""

from __future__ import annotations

import json
import re
import time
from datetime import datetime, timedelta, timezone
import urllib.error
import urllib.parse
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable

from credit_review.evidence import CONFIRMED, CONTRADICTED, classify_roles
from credit_review.judge import domain_matches_name, registrable_domain
from credit_review.roles import ONE_PERSON_FAMILIES, family_of, fold, names_match

POSITIVE, CONTRADICTS, SOFT, WEAK, UNKNOWN, ERROR, SKIPPED = (
    "positive", "contradicts", "soft", "weak", "unknown", "error", "skipped")

FREEMAIL = frozenset({
    "gmail.com", "googlemail.com", "yahoo.com", "yahoo.co.uk", "ymail.com", "hotmail.com", "hotmail.co.uk",
    "outlook.com", "live.com", "msn.com", "icloud.com", "me.com", "mac.com", "aol.com", "proton.me",
    "protonmail.com", "gmx.com", "gmx.de", "gmx.net", "mail.ru", "yandex.ru", "yandex.com", "zoho.com",
    "qq.com", "163.com", "126.com", "naver.com", "web.de", "free.fr", "orange.fr", "libero.it", "uol.com.br",
    "bol.com.br", "terra.com.br", "hey.com", "fastmail.com", "tutanota.com", "rediffmail.com",
})

# Official domains of distributors, PROs and rights bodies: they issue most
# of the dashboards and letters users send, and most are not MusicBrainz
# labels. Keyed by the folded name; several names can share a domain.
OFFICIAL_DOMAINS: dict[str, tuple[str, ...]] = {
    "distrokid": ("distrokid.com",), "tunecore": ("tunecore.com",), "cd baby": ("cdbaby.com",),
    "cdbaby": ("cdbaby.com",), "amuse": ("amuse.io",), "ditto": ("dittomusic.com", "ditto.fm"),
    "ditto music": ("dittomusic.com",), "unitedmasters": ("unitedmasters.com",),
    "united masters": ("unitedmasters.com",), "awal": ("awal.com",), "the orchard": ("theorchard.com",),
    "believe": ("believe.com",), "onerpm": ("onerpm.com",), "symphonic": ("symphonic.com", "symphonicdistribution.com"),
    "symphonic distribution": ("symphonicdistribution.com", "symphonic.com"), "stem": ("stem.is",),
    "routenote": ("routenote.com",), "landr": ("landr.com",), "repost network": ("repostnetwork.com", "repost.co"),
    "vydia": ("vydia.com",), "empire": ("empi.re",), "ingrooves": ("ingrooves.com",), "fuga": ("fuga.com",),
    "label worx": ("labelworx.com",), "spinnup": ("spinnup.com",), "soundrop": ("soundrop.com",),
    "too lost": ("toolost.com",), "level": ("levelmusic.com",), "record union": ("recordunion.com",),
    "ascap": ("ascap.com",), "bmi": ("bmi.com",), "sesac": ("sesac.com",), "gmr": ("globalmusicrights.com",),
    "prs": ("prsformusic.com",), "prs for music": ("prsformusic.com",), "socan": ("socan.com", "socan.ca"),
    "gema": ("gema.de",), "sacem": ("sacem.fr",), "apra amcos": ("apraamcos.com.au",), "apra": ("apraamcos.com.au",),
    "jasrac": ("jasrac.or.jp",), "sgae": ("sgae.es",), "siae": ("siae.it",), "ecad": ("ecad.org.br",),
    "the mlc": ("themlc.com",), "mlc": ("themlc.com",), "songtrust": ("songtrust.com",),
    "soundexchange": ("soundexchange.com",), "ppl": ("ppluk.com",), "sound exchange": ("soundexchange.com",),
}
LABEL_ISSUERS = ("label",)
GENERIC = frozenset({"records", "record", "recordings", "music", "musique", "musica", "entertainment", "ent",
                     "group", "label", "labels", "publishing", "inc", "llc", "ltd", "limited", "gmbh", "co",
                     "company", "the", "productions", "production", "media", "sa", "srl", "bv", "ab", "llp"})
SIGNATORY_PATHS = ("/", "/about", "/about-us", "/team", "/contact", "/staff")


@dataclass
class Check:
    step: str
    status: str
    detail: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {"step": self.step, "status": self.status, "detail": self.detail}


class Net:
    """The network seam (tests pass a fake)."""

    def __init__(self, get: Callable[..., tuple[bytes, str]] | None = None, resolver: Any = None,
                 mb_pacer: Any = None):
        if get is None:
            from credit_trust.websearch import http_get
            get = http_get
        self._get = get
        self._resolver = resolver
        self._mb_pacer = mb_pacer        # pace.Pacer: 1 req/s across every reader process on the host

    def json(self, url: str) -> Any:
        body, _ = self._get(url, accept="application/json")
        return json.loads(body)

    def mb(self, path: str, params: dict[str, str]) -> Any:
        """MusicBrainz, paced to 1 req/s process-wide; 503 is its rate-limit
        answer and gets two paced retries."""
        from credit_trust.websearch import _MB_LAST, _MB_LOCK, MB_MIN_INTERVAL_S
        url = f"https://musicbrainz.org/ws/2/{path}?" + urllib.parse.urlencode({**params, "fmt": "json"})
        for attempt in range(3):
            if self._mb_pacer is not None:
                self._mb_pacer.wait()
            with _MB_LOCK:
                wait = MB_MIN_INTERVAL_S - (time.monotonic() - _MB_LAST[0])
                if _MB_LAST[0] and wait > 0:
                    time.sleep(wait)
                _MB_LAST[0] = time.monotonic()
            try:
                return self.json(url)
            except urllib.error.HTTPError as exc:
                if exc.code != 503 or attempt == 2:
                    raise
                time.sleep(2.5 * (attempt + 1))
        raise RuntimeError("unreachable")

    def text(self, url: str) -> str:
        from credit_trust.websearch import html_to_text
        body, ctype = self._get(url, accept="text/html")
        raw = body.decode("utf-8", "replace")
        return html_to_text(raw) if "html" in (ctype or "html") else raw

    def mx(self, domain: str) -> str:
        """'mx' | 'no_mx' (domain exists, no MX) | 'nxdomain' | 'error'."""
        try:
            import dns.exception
            import dns.resolver
        except ImportError:
            return "error"
        res = self._resolver or dns.resolver.Resolver()
        try:
            ans = res.resolve(domain, "MX", lifetime=8)
            return "mx" if len(ans) else "no_mx"
        except dns.resolver.NXDOMAIN:
            return "nxdomain"
        except dns.resolver.NoAnswer:
            return "no_mx"
        except (dns.exception.DNSException, OSError):
            return "error"


def org_key(name: str | None) -> frozenset[str]:
    return frozenset(t for t in fold(name or "").split() if t not in GENERIC)


def org_match(a: str | None, b: str | None) -> bool:
    ka, kb = org_key(a), org_key(b)
    if not ka or not kb:
        return False
    return ka == kb or (min(len(ka), len(kb)) >= 1 and (ka <= kb or kb <= ka) and max(len(ka), len(kb)) <= 4)


def name_on_page(name: str, text: str) -> bool:
    """Whole-word, in-order match of the folded name in the folded page."""
    n = fold(name)
    return len(n.split()) >= 2 and re.search(rf"(?<![a-z0-9]){re.escape(n)}(?![a-z0-9])", fold(text)) is not None


# -- xc_dsp -------------------------------------------------------------------
LIVE_DSPS = ("spotify", "tidal")
FRESH_MAX_AGE_DAYS = 30


def _ts(v: Any) -> datetime | None:
    try:
        t = datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


def live_anchor(raw_credits: list[dict[str, Any]], family: str, names: list[str], fresh_since: str | None,
                now: datetime | None = None) -> dict[str, bool]:
    """{spotify, tidal}: does each DSP credit the claimant in this role family on a capture
    taken at or after `fresh_since` (requested by this run) and within 30 days? The APPROVE
    tray needs BOTH (proof-loop lead §1 DECIDE); stored, MLC or Jaxsta rows never count."""
    now = now or datetime.now(timezone.utc)
    since = _ts(fresh_since) if fresh_since else None
    out = {}
    for dsp_name in LIVE_DSPS:
        out[dsp_name] = bool(since) and any(
            str((c.get("profile") or {}).get("source") or "").lower() == dsp_name
            and family_of(str(c.get("credit") or "")) == family
            and (_ts(c.get("updatedAt")) or since - timedelta(days=1)) >= since
            and now - (_ts(c.get("updatedAt")) or now) <= timedelta(days=FRESH_MAX_AGE_DAYS)
            and any(names_match(str((c.get("profile") or {}).get("name") or ""), n) for n in names if n)
            for c in raw_credits)
    return out


def live_contradiction(raw_credits: list[dict[str, Any]], family: str, names: list[str],
                       fresh_since: str | None, now: datetime | None = None) -> tuple[bool, list[str]]:
    """(contradicts, why-not). Fable [key=doc-verify-go-live] Q3, 2026-10-27: a credit is
    contradicted only on a fresh capture of BOTH Spotify and Tidal requested by this run
    (rows captured at or after `fresh_since`, and within 30 days), where each DSP credits
    exactly one other person, the same one, in this one-person role and not the claimant.
    Jaxsta, MLC or MusicBrainz alone never contradict. No requested capture (fresh_since
    None) means it cannot be shown: UNKNOWN never holds anyone."""
    now = now or datetime.now(timezone.utc)
    why: list[str] = []
    since = _ts(fresh_since) if fresh_since else None
    if since is None:
        why.append("no fresh Spotify+Tidal capture was requested by this run")
    others: dict[str, set[str]] = {}
    for dsp_name in LIVE_DSPS:
        rows = [c for c in raw_credits if str((c.get("profile") or {}).get("source") or "").lower() == dsp_name
                and family_of(str(c.get("credit") or "")) == family]
        fresh = [c for c in rows if since and (_ts(c.get("updatedAt")) or since - timedelta(days=1)) >= since
                 and now - (_ts(c.get("updatedAt")) or now) <= timedelta(days=FRESH_MAX_AGE_DAYS)]
        if since and not fresh:
            why.append(f"no fresh {dsp_name} capture for this role")
        if any(any(names_match(str((c.get("profile") or {}).get("name") or ""), n) for n in names if n)
               for c in (fresh or rows)):
            why.append(f"{dsp_name} credits the claimant")
        others[dsp_name] = {fold(str((c.get("profile") or {}).get("name") or "")) for c in (fresh or rows)} - {""}
    sp, ti = others["spotify"], others["tidal"]
    if len(sp) != 1 or len(ti) != 1 or sp != ti:
        why.append(f"not exactly one other person on both DSPs (spotify {len(sp)}, tidal {len(ti)})")
    return (not why), why


def dsp(raw_credits: list[dict[str, Any]] | None, role: str, names: list[str], err: str | None = None,
        fresh_since: str | None = None) -> Check:
    if raw_credits is None:
        return Check("xc_dsp", ERROR, {"error": err or "raw credits unavailable"})
    ev = classify_roles([role], raw_credits, names, set())[0]
    detail = {"family": ev.family, "status": ev.status, "for_claimant": ev.trusted_for_profile[:5],
              "for_others": ev.trusted_for_others[:5], "capture": "muso catalog raw credits (spotify/tidal/mlc/jaxsta)",
              "captured_at": max((str(c.get("updatedAt") or "") for c in raw_credits), default=None) or None,
              "fresh_since": fresh_since,
              "fresh_anchor": live_anchor(raw_credits, ev.family, names, fresh_since)}
    if ev.status == CONFIRMED:
        return Check("xc_dsp", POSITIVE, detail)
    if ev.status == CONTRADICTED:
        ok, why = live_contradiction(raw_credits, ev.family, names, fresh_since)
        if ok:
            return Check("xc_dsp", CONTRADICTS, detail)
        detail.update(note="possible conflict, not a contradiction: " + "; ".join(why), dsp_conflict=True)
        return Check("xc_dsp", UNKNOWN, detail)
    return Check("xc_dsp", UNKNOWN, detail)


# -- xc_isrc ------------------------------------------------------------------
@dataclass
class Release:
    isrc: str
    mb_rels: list[dict[str, str]] = field(default_factory=list)      # {name, type}
    deezer_contributors: list[dict[str, str]] = field(default_factory=list)
    label: str | None = None
    errors: list[str] = field(default_factory=list)


def release_facts(net: Net, isrc: str) -> Release:
    r = Release(isrc)
    try:
        data = net.mb(f"isrc/{isrc}", {})
        for rec in (data.get("recordings") or [])[:2]:
            full = net.mb(f"recording/{rec['id']}", {"inc": "artist-credits+artist-rels"})
            for rel in full.get("relations") or []:
                who = (rel.get("artist") or {}).get("name")
                if who:
                    r.mb_rels.append({"name": who, "type": " ".join([rel.get("type") or ""] + list(rel.get("attributes") or []))})
    except urllib.error.HTTPError as exc:
        if exc.code != 404:
            r.errors.append(f"musicbrainz http {exc.code}")
    except Exception as exc:  # noqa: BLE001 - one source failing is recorded, never fatal
        r.errors.append(f"musicbrainz {type(exc).__name__}")
    try:
        t = net.json(f"https://api.deezer.com/track/isrc:{isrc}")
        if isinstance(t, dict) and not t.get("error"):
            r.deezer_contributors = [{"name": c.get("name"), "type": c.get("role") or ""}
                                     for c in t.get("contributors") or [] if c.get("name")]
            alb = (t.get("album") or {}).get("id")
            if alb:
                a = net.json(f"https://api.deezer.com/album/{alb}")
                if isinstance(a, dict) and a.get("label"):
                    r.label = str(a["label"])[:120]
    except Exception as exc:  # noqa: BLE001
        r.errors.append(f"deezer {type(exc).__name__}")
    return r


def isrc_check(rel: Release | None, role: str, names: list[str]) -> Check:
    if rel is None:
        return Check("xc_isrc", SKIPPED, {"why": "no ISRC for the track"})
    fam = family_of(role)
    mine = [x for x in rel.mb_rels if family_of(x["type"]) == fam and any(names_match(x["name"], n) for n in names)]
    others = [x for x in rel.mb_rels if family_of(x["type"]) == fam and x not in mine]
    detail = {"isrc": rel.isrc, "registrant": rel.isrc[2:5], "family": fam, "musicbrainz_for_claimant": mine[:5],
              "musicbrainz_for_others": others[:5], "deezer_label": rel.label,
              "deezer_contributors": rel.deezer_contributors[:8], "errors": rel.errors}
    if mine:
        return Check("xc_isrc", POSITIVE, detail)
    if rel.errors and not rel.mb_rels:
        return Check("xc_isrc", ERROR, detail)
    if others and fam in ONE_PERSON_FAMILIES:
        detail["note"] = "MusicBrainz credits someone else in this one-person role (community data: not a contradiction)"
        return Check("xc_isrc", SOFT, detail)
    return Check("xc_isrc", UNKNOWN, detail)


# -- issuer ---------------------------------------------------------------------
def label_check(issuer: str | None, issuer_type: str | None, rel: Release | None) -> Check:
    if not issuer:
        return Check("xc_label", SKIPPED, {"why": "the document names no issuer"})
    if issuer_type not in LABEL_ISSUERS:
        return Check("xc_label", SKIPPED, {"why": f"issuer type {issuer_type}: only a label is compared with the "
                                                   "release's label line", "issuer": issuer})
    if rel is None or not rel.label:
        return Check("xc_label", UNKNOWN, {"issuer": issuer, "why": "release label unknown"})
    detail = {"issuer": issuer, "release_label": rel.label, "isrc_registrant": rel.isrc[2:5]}
    if org_match(issuer, rel.label):
        return Check("xc_label", POSITIVE, detail)
    detail["note"] = "the claimed issuer is not the release's label line"
    return Check("xc_label", SOFT, detail)


def official_domains(net: Net, issuer: str | None) -> tuple[list[str], str]:
    """(domains, how found). Independent of the document: the fixed
    distributor/PRO table, else MusicBrainz label url-rels."""
    if not issuer:
        return [], "no issuer"
    k = fold(issuer)
    for name, doms in OFFICIAL_DOMAINS.items():
        if k == name or re.search(rf"(?<![a-z0-9]){re.escape(name)}(?![a-z0-9])", k):
            return list(doms), f"official domain table ({name})"
    try:
        data = net.mb("label", {"query": f'label:"{issuer[:80]}"', "limit": "5"})
        for lab in data.get("labels") or []:
            if int(lab.get("score") or 0) < 95 or not org_match(lab.get("name"), issuer):
                continue
            full = net.mb(f"label/{lab['id']}", {"inc": "url-rels"})
            doms = []
            for r in full.get("relations") or []:
                if r.get("type") == "official homepage":
                    host = urllib.parse.urlparse((r.get("url") or {}).get("resource") or "").hostname or ""
                    if host:
                        doms.append(registrable_domain(host))
            if doms:
                return list(dict.fromkeys(doms)), f"musicbrainz label {lab['id']}"
    except Exception as exc:  # noqa: BLE001
        return [], f"musicbrainz error {type(exc).__name__}"
    return [], "not found"


# Below this extraction confidence a sender address is not evidence either
# way: an OCR/model misread must never forge a document or hold an account.
SENDER_MIN_CONFIDENCE = 0.6


def domain_check(net: Net, sender_domain: str | None, issuer: str | None, official: list[str], how: str,
                 confidence: float = 1.0) -> Check:
    if not sender_domain:
        return Check("xc_domain", SKIPPED, {"why": "no sender email on the document"})
    dom = registrable_domain(sender_domain)
    detail: dict[str, Any] = {"sender_domain": dom, "issuer": issuer, "official": official, "official_from": how,
                              "confidence": confidence}
    if not confidence >= SENDER_MIN_CONFIDENCE:          # NaN fails this too
        detail["note"] = (f"sender read with confidence {confidence:.2f} (< {SENDER_MIN_CONFIDENCE}): "
                          "not evidence either way")
        return Check("xc_domain", WEAK, detail)
    if dom in FREEMAIL:
        detail["note"] = "free-mail address: it cannot show the issuer sent it"
        return Check("xc_domain", WEAK, detail)
    mx = net.mx(dom)
    detail["mx"] = mx
    if mx == "nxdomain":
        detail["note"] = "the sender's domain does not exist"
        return Check("xc_domain", CONTRADICTS, detail)
    if official:
        if dom in official:
            return Check("xc_domain", POSITIVE if mx != "no_mx" else SOFT, detail)
        if issuer and domain_matches_name(dom, [issuer]):
            detail["note"] = "look-alike: the domain carries the issuer's name but is not its official domain"
            return Check("xc_domain", CONTRADICTS, detail)
        detail["note"] = "the sender's domain is not the issuer's official domain"
        return Check("xc_domain", SOFT, detail)
    if mx == "no_mx":
        detail["note"] = "the sender's domain receives no mail"
        return Check("xc_domain", SOFT, detail)
    detail["note"] = "the issuer's official domain could not be found independently"
    return Check("xc_domain", UNKNOWN, detail)


def signatory_check(net: Net, signatory: str | None, official: list[str]) -> Check:
    if not signatory:
        return Check("xc_signatory", SKIPPED, {"why": "no signatory on the document"})
    if not official:
        return Check("xc_signatory", UNKNOWN, {"signatory": signatory, "why": "no official issuer site to check"})
    tried, errors = [], []
    for dom in official[:2]:
        for p in SIGNATORY_PATHS:
            url = f"https://{dom}{p}"
            tried.append(url)
            try:
                if name_on_page(signatory, net.text(url)):
                    return Check("xc_signatory", POSITIVE, {"signatory": signatory, "found_on": url})
            except Exception as exc:  # noqa: BLE001
                errors.append(f"{p}: {type(exc).__name__}")
    return Check("xc_signatory", UNKNOWN, {"signatory": signatory, "tried": tried, "errors": errors[:6],
                                           "why": "not found on the issuer's official pages (not a contradiction)"})


def by_step(checks: Iterable[Check]) -> dict[str, Check]:
    return {c.step: c for c in checks}
