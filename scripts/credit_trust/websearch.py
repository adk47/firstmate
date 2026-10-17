"""Free, server-side web evidence for the credit-trust judge: SEARCH and FETCH
are ours, JUDGING is the model's (firstmate 001, captain "$0 first").

Why split them: Codex cannot search headlessly on codex-cli 0.156.1 (T01
spike), and a model that "searches" for us returns URLs we cannot re-read. Here
the server finds and fetches the pages, keeps a sha256'd snapshot of every
fetched body, and hands the model numbered SOURCES. The model may only cite a
source id plus a passage quoted from it; credibility.verify_findings keeps a
finding only when that passage is really in the snapshot. The evidence a case
event cites is therefore (url, snapshot sha256, quoted passage) - all of it
re-checkable without trusting the model.

Sources, all $0 and all reachable from node-8 (checked 2026-10-15):
  * musicbrainz - recording by ISRC (exact) or title+artist, with artist
                  relationships (mix, producer, engineer, instrument, ...).
                  The best free structured credits source. 1 req/s, UA required.
  * wikipedia   - search API -> article HTML (personnel sections).
  * searxng     - only if CREDIT_TRUST_SEARXNG_URL is set (none deployed yet).
  * brave       - only if BRAVE_SEARCH_API_KEY is set (free tier needs a signup).
General HTML search engines (DuckDuckGo html/lite, Mojeek, Brave HTML) answer
node-8's OVH address with a captcha or 429, so they are not used.

Fetching is SSRF-guarded: http(s) only, every resolved address must be public
(no loopback / private / link-local / reserved), the socket connects to an
address that passed that check (no second DNS lookup to rebind), redirects are
re-checked, no proxy is used, and bodies are capped. The fetched text is untrusted DATA for the model.
"""

from __future__ import annotations

import hashlib
import html
import http.client
import ipaddress
import json
import os
import re
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

UA = os.environ.get("CREDIT_TRUST_HTTP_UA", "hydra-credit-trust/1.0 ( ops@muso.ai )")
SNAPSHOT_DIR = os.environ.get("CREDIT_TRUST_SNAPSHOTS", "/var/lib/hydra/credit-trust/snapshots")
SEARXNG_URL = os.environ.get("CREDIT_TRUST_SEARXNG_URL", "")
BRAVE_KEY = os.environ.get("BRAVE_SEARCH_API_KEY", "")
MAX_BODY_BYTES = 2_000_000
MAX_DOC_CHARS = 9_000          # per source handed to the model
FETCH_TIMEOUT_S = 20
MB_MIN_INTERVAL_S = 1.1        # MusicBrainz rate limit: 1 request/second, per IP
# The MusicBrainz limit is per client IP, so it is enforced process-wide (the
# eval and the runner judge rows from a thread pool), not per Searcher.
_MB_LOCK = threading.Lock()
_MB_LAST = [0.0]

# Pages on our own domain repeat the claim itself: never a source.
SKIP_HOST_SUFFIXES = ("muso.ai",)


@dataclass
class Doc:
    source_id: str
    url: str
    title: str
    engine: str
    text: str
    body_sha256: str
    text_sha256: str
    fetched_at: str
    snapshot_path: str | None = None

    def brief(self) -> dict[str, Any]:
        return {"source_id": self.source_id, "url": self.url, "title": self.title, "engine": self.engine,
                "body_sha256": self.body_sha256, "text_sha256": self.text_sha256, "fetched_at": self.fetched_at,
                "chars": len(self.text)}


@dataclass
class Gathered:
    docs: list[Doc] = field(default_factory=list)
    trace: list[dict[str, Any]] = field(default_factory=list)


class FetchRefused(Exception):
    pass


def public_addresses(host: str, resolver: Callable[..., Any] | None = None) -> list[str]:
    """Every address the host resolves to, when ALL are public unicast IPs;
    [] otherwise."""
    try:
        infos = (resolver or socket.getaddrinfo)(host, None)
    except (socket.gaierror, UnicodeError, OSError):
        return []
    addrs = list(dict.fromkeys(i[4][0] for i in infos))
    for a in addrs:
        try:
            ip = ipaddress.ip_address(a.split("%")[0])
        except ValueError:
            return []
        if (ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_multicast
                or ip.is_unspecified or not ip.is_global):
            return []
    return addrs


def public_host(host: str, resolver: Callable[..., Any] | None = None) -> bool:
    """True when every address the host resolves to is a public unicast IP."""
    return bool(public_addresses(host, resolver))


def _dial_public(address: tuple[str, int], *args: Any, **kwargs: Any) -> socket.socket:
    """socket.create_connection for the fetcher: the host is resolved ONCE here,
    checked, and the socket goes to an address that passed the check, so a DNS
    answer that changes between check_url and the connect (rebinding) cannot
    reach a private address."""
    host, port = address
    addrs = public_addresses(host)
    if not addrs:
        raise FetchRefused(f"host does not resolve to public addresses only: {host}")
    return socket.create_connection((addrs[0], port), *args, **kwargs)


class _PinnedHTTPConnection(http.client.HTTPConnection):
    def __init__(self, *args: Any, **kwargs: Any):
        super().__init__(*args, **kwargs)
        self._create_connection = _dial_public


class _PinnedHTTPSConnection(http.client.HTTPSConnection):
    """Dials the checked address; TLS SNI and the certificate check still use
    the hostname."""

    def __init__(self, *args: Any, **kwargs: Any):
        super().__init__(*args, **kwargs)
        self._create_connection = _dial_public


class _PinnedHTTPHandler(urllib.request.HTTPHandler):
    def http_open(self, req):
        return self.do_open(_PinnedHTTPConnection, req)


class _PinnedHTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(_PinnedHTTPSConnection, req, context=self._context)


def check_url(url: str, resolver: Callable[..., Any] | None = None) -> str:
    p = urllib.parse.urlparse(url)
    if p.scheme not in ("http", "https") or not p.hostname:
        raise FetchRefused(f"not an http(s) URL: {url[:120]}")
    try:
        port = p.port
    except ValueError as exc:
        raise FetchRefused(f"bad port: {url[:120]}") from exc
    if port not in (None, 80, 443):
        raise FetchRefused(f"non-standard port refused: {url[:120]}")
    if not public_host(p.hostname, resolver):
        raise FetchRefused(f"host does not resolve to public addresses only: {p.hostname}")
    return url


class _GuardedRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def http_get(url: str, *, accept: str = "*/*", timeout: int = FETCH_TIMEOUT_S,
             headers: dict[str, str] | None = None) -> tuple[bytes, str]:
    """GET with the SSRF guard; returns (body, content-type). Body capped."""
    check_url(url)
    # No proxy: a proxy would resolve the host itself, outside the pinned dial.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), _PinnedHTTPHandler, _PinnedHTTPSHandler,
                                         _GuardedRedirect)
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": accept, **(headers or {})})
    with opener.open(req, timeout=timeout) as resp:
        body = resp.read(MAX_BODY_BYTES + 1)[:MAX_BODY_BYTES]
        return body, resp.headers.get("Content-Type", "")


# Quoted attribute values may contain ">" (Wikipedia's data-mw JSON does), so a
# tag is matched attribute-aware rather than up to the first ">".
_TAG = re.compile(r"""<(?:"[^"]*"|'[^']*'|[^'">])*>""")
_DROP = re.compile(r"<(script|style|noscript|svg|head)\b.*?</\1>", re.S | re.I)
_BLOCK = re.compile(r"""</?(?:p|div|li|tr|td|th|h[1-6]|br|table|section|dd|dt)\b(?:"[^"]*"|'[^']*'|[^'">])*>""", re.I)


def html_to_text(raw: str) -> str:
    s = _DROP.sub(" ", raw)
    s = _BLOCK.sub("\n", s)
    s = _TAG.sub(" ", s)
    s = html.unescape(s)
    s = re.sub(r"[ \t\r\f\v]+", " ", s)
    s = re.sub(r"\n\s*\n+", "\n", s)
    return s.strip()


def norm_passage(s: str) -> str:
    """Whitespace/case/quote-folded form used to check a quoted passage."""
    s = html.unescape(s or "").lower()
    for a, b in (("\u2019", "'"), ("\u2018", "'"), ("\u201c", '"'), ("\u201d", '"'), ("\u2010", "-"),
                 ("\u2011", "-"), ("\u2013", "-"), ("\u2014", "-"), ("\u00a0", " ")):
        s = s.replace(a, b)
    return re.sub(r"\s+", " ", s).strip()


Getter = Callable[..., tuple[bytes, str]]


class Searcher:
    def __init__(self, snapshot_dir: str | None = SNAPSHOT_DIR, *, get: Getter | None = None,
                 sleep: Callable[[float], None] = time.sleep, max_docs: int = 6):
        self.snapshot_dir = Path(snapshot_dir) if snapshot_dir else None
        self._get = get or http_get
        self._sleep = sleep
        self.max_docs = max_docs

    def gather(self, claim: dict[str, Any]) -> Gathered:
        """claim: {person, roles[], track_title, artists[], isrc?}."""
        g = Gathered()
        for name, fn in (("musicbrainz", self._musicbrainz), ("wikipedia", self._wikipedia),
                         ("searxng", self._searxng), ("brave", self._brave)):
            if len(g.docs) >= self.max_docs:
                break
            try:
                docs, note = fn(claim, self.max_docs - len(g.docs))
            except Exception as exc:  # noqa: BLE001 - one source failing must not end the check
                g.trace.append({"engine": name, "error": f"{type(exc).__name__}: {exc}"[:200]})
                continue
            g.trace.append({"engine": name, "docs": len(docs), **({"note": note} if note else {})})
            seen = {d.url for d in g.docs}
            g.docs += [d for d in docs if d.url not in seen]
        for i, d in enumerate(g.docs, 1):
            d.source_id = f"S{i}"
        return g

    # ── snapshots ─────────────────────────────────────────────────────────
    def _doc(self, url: str, title: str, engine: str, body: bytes, text: str) -> Doc:
        body_sha = hashlib.sha256(body).hexdigest()
        text = text[:MAX_DOC_CHARS]
        d = Doc(source_id="", url=url, title=str(title)[:200], engine=engine, text=text, body_sha256=body_sha,
                text_sha256=hashlib.sha256(text.encode("utf-8")).hexdigest(),
                fetched_at=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        if self.snapshot_dir is not None:
            p = self.snapshot_dir / f"{body_sha}.json"
            try:
                self.snapshot_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
                fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    json.dump({"url": url, "engine": engine, "fetched_at": d.fetched_at, "body_sha256": body_sha,
                               "text_sha256": d.text_sha256, "text": text,
                               "body": body.decode("utf-8", "replace")}, fh, ensure_ascii=False)
                d.snapshot_path = str(p)
            except FileExistsError:
                d.snapshot_path = str(p)    # same bytes already kept (content-addressed)
            except OSError:
                d.snapshot_path = None
        return d

    def _fetch_page(self, url: str, title: str, engine: str) -> Doc | None:
        host = (urllib.parse.urlparse(url).hostname or "").lower()
        if any(host == s or host.endswith("." + s) for s in SKIP_HOST_SUFFIXES):
            return None
        body, ctype = self._get(url, accept="text/html,application/xhtml+xml")
        if "html" not in ctype and "text" not in ctype:
            return None
        text = html_to_text(body.decode("utf-8", "replace"))
        return self._doc(url, title, engine, body, text) if text else None

    # ── musicbrainz ───────────────────────────────────────────────────────
    def _mb(self, path: str, params: dict[str, str]) -> tuple[bytes, Any]:
        with _MB_LOCK:
            wait = MB_MIN_INTERVAL_S - (time.monotonic() - _MB_LAST[0])
            if _MB_LAST[0] and wait > 0:
                self._sleep(wait)
            _MB_LAST[0] = time.monotonic()
        url = f"https://musicbrainz.org/ws/2/{path}?" + urllib.parse.urlencode({**params, "fmt": "json"})
        try:
            body, _ = self._get(url, accept="application/json")
        except urllib.error.HTTPError as exc:
            if exc.code != 503:     # 503 is MusicBrainz's rate-limit answer: one paced retry
                raise
            self._sleep(2.5)
            with _MB_LOCK:
                _MB_LAST[0] = time.monotonic()
            body, _ = self._get(url, accept="application/json")
        return body, json.loads(body)

    def _musicbrainz(self, claim: dict[str, Any], room: int) -> tuple[list[Doc], str | None]:
        title = (claim.get("track_title") or "").strip()
        artists = [a for a in claim.get("artists") or [] if a]
        rec_ids: list[str] = []
        isrc = (claim.get("isrc") or "").strip().upper()
        if re.fullmatch(r"[A-Z]{2}[A-Z0-9]{3}\d{7}", isrc):
            try:
                _, data = self._mb(f"isrc/{isrc}", {})
                rec_ids = [r["id"] for r in data.get("recordings") or [] if not r.get("disambiguation")][:2]
            except urllib.error.HTTPError as exc:
                if exc.code != 404:
                    raise
        if not rec_ids and title:
            base = re.sub(r"\s+-\s+.*$", "", title)    # "Come Together - Remastered 2009" -> "Come Together"
            q = f'recording:"{_mb_escape(base)}"' + (f' AND artist:"{_mb_escape(artists[0])}"' if artists else "")
            _, data = self._mb("recording", {"query": q, "limit": "8"})
            first = artists[0].lower() if artists else ""
            for r in data.get("recordings") or []:
                if int(r.get("score") or 0) < 90 or r.get("disambiguation"):
                    continue   # live takes, remixes and Atmos mixes are other recordings
                credit = " ".join(a.get("name", "") for a in r.get("artist-credit") or []).lower()
                if first and first not in credit:
                    continue
                rec_ids.append(r["id"])
                if len(rec_ids) >= 4:
                    break
        # Title search returns several same-titled recordings (single edits,
        # compilation copies); credits usually sit on one of them. Keep the
        # ones that actually carry artist relationships.
        docs = []
        for rid in rec_ids:
            if len(docs) >= min(2, room):
                break
            body, rec = self._mb(f"recording/{rid}", {"inc": "artist-credits+artist-rels+releases"})
            if not any((r.get("artist") or {}).get("name") for r in rec.get("relations") or []):
                continue
            docs.append(self._doc(f"https://musicbrainz.org/recording/{rid}", f"MusicBrainz: {rec.get('title')}",
                                  "musicbrainz", body, render_mb_recording(rec)))
        if docs:
            return docs, None
        return [], "no matching recording" if not rec_ids else "matching recordings carry no credits"

    # ── wikipedia ─────────────────────────────────────────────────────────
    def _wikipedia(self, claim: dict[str, Any], room: int) -> tuple[list[Doc], str | None]:
        title = re.sub(r"\s+-\s+.*$", "", (claim.get("track_title") or "").strip())
        if not title or room <= 0:
            return [], "no title"
        artists = [a for a in claim.get("artists") or [] if a]
        q = f'"{title}" {artists[0] if artists else ""} song'.strip()
        url = "https://en.wikipedia.org/w/api.php?" + urllib.parse.urlencode(
            {"action": "query", "list": "search", "srsearch": q, "srlimit": "3", "format": "json"})
        body, _ = self._get(url, accept="application/json")
        hits = (json.loads(body).get("query") or {}).get("search") or []
        tnorm = norm_passage(title)
        for h in hits:
            page = str(h.get("title") or "")
            if tnorm and tnorm not in norm_passage(page):
                continue   # only the track's own article
            enc = urllib.parse.quote(page.replace(" ", "_"), safe="")
            body, _ = self._get(f"https://en.wikipedia.org/api/rest_v1/page/html/{enc}", accept="text/html")
            text = html_to_text(body.decode("utf-8", "replace"))
            return [self._doc(f"https://en.wikipedia.org/wiki/{enc}", f"Wikipedia: {page}", "wikipedia",
                              body, _personnel_first(text))], None
        return [], "no article for the track"

    # ── optional general web engines ──────────────────────────────────────
    def _queries(self, claim: dict[str, Any]) -> list[str]:
        title = claim.get("track_title") or ""
        artist = (claim.get("artists") or [""])[0]
        person = claim.get("person") or ""
        return [q for q in (f'"{title}" {artist} credits', f'"{person}" "{title}"') if q.replace('"', "").strip()]

    def _searxng(self, claim: dict[str, Any], room: int) -> tuple[list[Doc], str | None]:
        if not SEARXNG_URL:
            return [], "not configured (CREDIT_TRUST_SEARXNG_URL unset)"
        urls: list[tuple[str, str]] = []
        for q in self._queries(claim):
            body, _ = self._get(SEARXNG_URL.rstrip("/") + "/search?" + urllib.parse.urlencode({"q": q, "format": "json"}),
                                accept="application/json")
            urls += [(r.get("url", ""), r.get("title", "")) for r in json.loads(body).get("results") or []][:4]
        return self._fetch_many(urls, "searxng", room), None

    def _brave(self, claim: dict[str, Any], room: int) -> tuple[list[Doc], str | None]:
        if not BRAVE_KEY:
            return [], "not configured (BRAVE_SEARCH_API_KEY unset)"
        urls: list[tuple[str, str]] = []
        for q in self._queries(claim):
            body, _ = self._get("https://api.search.brave.com/res/v1/web/search?"
                                + urllib.parse.urlencode({"q": q, "count": "5"}),
                                accept="application/json", headers={"X-Subscription-Token": BRAVE_KEY})
            urls += [(r.get("url", ""), r.get("title", ""))
                     for r in (json.loads(body).get("web") or {}).get("results") or []]
        return self._fetch_many(urls, "brave", room), None

    def _fetch_many(self, urls: list[tuple[str, str]], engine: str, room: int) -> list[Doc]:
        docs: list[Doc] = []
        for url, title in dict.fromkeys(urls):
            if len(docs) >= room:
                break
            try:
                d = self._fetch_page(url, title, engine)
            except (FetchRefused, urllib.error.URLError, TimeoutError, OSError, ValueError):
                continue
            if d:
                docs.append(d)
        return docs


def _mb_escape(s: str) -> str:
    return re.sub(r'([+\-&|!(){}\[\]^"~*?:\\/])', r"\\\1", s)


def render_mb_recording(rec: dict[str, Any]) -> str:
    """Deterministic text for a MusicBrainz recording: what the model reads and
    what a quoted passage is checked against."""
    lines = [f"MusicBrainz recording: {rec.get('title')}"]
    ac = "".join(f"{a.get('name', '')}{a.get('joinphrase', '')}" for a in rec.get("artist-credit") or [])
    if ac:
        lines.append(f"Artist: {ac}")
    rels = sorted({r.get("title") for r in rec.get("releases") or [] if isinstance(r, dict) and r.get("title")})
    if rels:
        lines.append("Released on: " + "; ".join(rels[:5]))
    lines.append("Credits:")
    for r in rec.get("relations") or []:
        who = (r.get("artist") or {}).get("name")
        if not who:
            continue
        attrs = ", ".join(r.get("attributes") or [])
        lines.append(f"- {r.get('type') or ''}{f' ({attrs})' if attrs else ''}: {who}")
    return "\n".join(lines)


LEAD_CHARS = 3_500
SECTION_CHARS = MAX_DOC_CHARS - LEAD_CHARS - 20
_CREDITS_HEADING = re.compile(r"\n\s*(Personnel|Credits and personnel|Credits|Track listing and credits)\s*\n", re.I)


def _personnel_first(text: str) -> str:
    """The article lead (infobox: producer, songwriters, label) plus its
    personnel/credits section, so the per-source cap keeps both. Articles
    without such a section keep their opening text."""
    m = _CREDITS_HEADING.search(text, LEAD_CHARS // 2)
    if not m:
        return text
    return text[:LEAD_CHARS] + "\n[...]\n" + text[m.start():m.start() + SECTION_CHARS]
