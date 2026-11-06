"""Same-run read-backs behind the confirmation lines (erasure-confirmation-template.md verification table).

  S  search    anonymous public autocomplete (api.muso.ai v5) for the page's exact / lowercase / prefix name
               returns no item with the page's id AND fewer than its cap (the endpoint has no paging, so a full
               page means "not shown", never "not there")
  P  public    anonymous GET of https://muso.ai/profile/<id> and /credits -> 410 AND x-robots-tag noindex
  M  sitemap   every file reachable from https://muso.ai/sitemap.xml (index -> child indexes -> url sets, .gz
               handled) read in this run, and none carries a URL for the id. One unreadable file = M not
               verified (a partial scan never fills a line).

Each returns True (verified), False (checked, not done) or raises Unknown (could not check). Only True fills a
line. Nothing here writes.
"""
from __future__ import annotations

import gzip
import json
import re
import urllib.error
import urllib.parse
import urllib.request

from gdpr_pipeline.sources import Unknown


class Unmeasurable(Unknown):
    """This row cannot be checked HERE, and no retry will change that.

    A subclass of `Unknown` on purpose: it is still never a verdict, so every existing `except Unknown` keeps
    refusing to fill a line. What it adds is a distinction the tick needs. `Unknown` covers two different things:

    - **unreadable** - an HTTP 500, a non-JSON body, a schema change. The next tick may well succeed, so the run
      must report it and the caller must keep its window open.
    - **unmeasurable** - the row has no page name to search for, or its name matches more pages than the
      autocomplete cap can show. Measured on node-8 on 2026-11-06: 31 rows of the second kind, every tick, for
      ever. Retrying is not a plan; a person confirming in the app search is.

    Conflating them made the tick exit 2 sixteen times in one day and page #clio_devops daily for a condition that
    can never clear, which is how a real failure gets missed. An unmeasurable row is still NOT confirmed - it drops
    out of the confirmation batch and the watchdog keeps naming it, which is the human's queue.
    """


UA = "Mozilla/5.0 (muso-gdpr-pipeline read-back)"
AUTOCOMPLETE = "https://api.muso.ai/api/v5/search/autocomplete?q={q}&limit=20"
# The endpoint ignores limit/offset/page/cursor and returns at most its own cap; a full page is NOT exhaustive.
AUTOCOMPLETE_CAP = 30
SITEMAP_INDEX = "https://muso.ai/sitemap.xml"
MAX_SITEMAP_FILES = 6000


def _get(url: str, timeout: int = 60) -> tuple[int, dict, bytes]:
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Encoding": "identity"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, {k.lower(): v for k, v in r.headers.items()}, r.read()
    except urllib.error.HTTPError as exc:
        return exc.code, {k.lower(): v for k, v in (exc.headers or {}).items()}, b""
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise Unknown(f"GET {url}: {exc}") from exc


def public_gone(entity: str, pid: str) -> bool:
    """P: 410 + noindex on the page and (for a profile) its /credits sub-page."""
    paths = [f"/{entity}/{pid}"] + ([f"/profile/{pid}/credits"] if entity == "profile" else [])
    for path in paths:
        status, headers, _ = _get("https://muso.ai" + path)
        if status >= 500:
            raise Unknown(f"P check {path}: HTTP {status}")
        if status != 410 or "noindex" not in headers.get("x-robots-tag", "").lower():
            return False
    return True


def search_absent(pid: str, name: str, fetch=_get) -> bool:
    """S: the id is not among the suggestions for its exact, lowercase or prefix name, and the answer was not a
    truncated page (the endpoint cannot page, so a full page proves nothing about what it left out)."""
    if not name.strip():
        raise Unmeasurable("S check: no page name to search for")
    prefix = name.strip()[:max(3, (len(name.strip()) * 3) // 5)]
    for q in {name.strip(), name.strip().lower(), prefix}:
        status, _, body = fetch(AUTOCOMPLETE.format(q=urllib.parse.quote(q)))
        if status != 200:
            raise Unknown(f"S check: autocomplete HTTP {status}")
        try:
            doc = json.loads(body)
        except ValueError as exc:
            raise Unknown("S check: autocomplete returned non-JSON") from exc
        # A schema change must NEVER read as "not in search": that is the S line of a customer letter.
        if not isinstance(doc, dict) or not isinstance(doc.get("data"), dict) \
                or not isinstance(doc["data"].get("items"), list):
            raise Unknown("S check: autocomplete response has no data.items list (schema change?)")
        items = doc["data"]["items"]
        if any(str(i.get("id", "")).lower() == pid for i in items):
            return False
        # The endpoint has NO paging: it ignores limit/offset/page/take and always answers with its own cap
        # (measured 2026-11-02: limit=20 and limit=200 both return 30 items, offset/page/cursor change nothing).
        # So a FULL page means "we did not see the id in what it was willing to show", not "the id is not there":
        # a name with more matches than the cap can hide the target below the cut. Absence must never be guessed —
        # it is the S line of a customer letter.
        if len(items) >= AUTOCOMPLETE_CAP:
            raise Unmeasurable(f"S check: '{q}' returned the full autocomplete page ({len(items)} items, cap "
                               f"{AUTOCOMPLETE_CAP}) without the id; a name with more matches than the cap cannot "
                               f"be checked here - confirm in the app search")
    return True


LOC_RE = re.compile(rb"<loc>\s*([^<\s]+)\s*</loc>")


def sitemap_absent(ids: list[str], fetch=_get) -> dict[str, bool]:
    """M for many ids in one walk: {id: True when no sitemap file carries it}. Raises Unknown on any unreadable
    file or when the walk exceeds MAX_SITEMAP_FILES (a partial scan is not a check)."""
    want = {i.lower().encode() for i in ids}
    found: set[bytes] = set()
    queue, seen = [SITEMAP_INDEX], set()
    while queue:
        url = queue.pop()
        if url in seen:
            continue
        seen.add(url)
        if len(seen) > MAX_SITEMAP_FILES:
            raise Unknown(f"M check: more than {MAX_SITEMAP_FILES} sitemap files; refusing a partial scan")
        status, _, body = fetch(url)
        if status != 200:
            raise Unknown(f"M check: {url} HTTP {status}")
        if body[:2] == b"\x1f\x8b":
            body = gzip.decompress(body)
        # A 200 that is not a sitemap (an HTML error page, an empty body, a CDN stub) must NEVER read as "no file
        # carries the id": that is the M line of a customer letter.
        head = body[:1000].lower()
        if b"<sitemapindex" in head:
            locs = [m.decode() for m in LOC_RE.findall(body)]
            if not locs:
                raise Unknown(f"M check: sitemap index {url} lists no <loc> children")
            queue += locs
            continue
        if b"<urlset" not in head:
            raise Unknown(f"M check: {url} is not a sitemap (HTTP 200, {len(body)} bytes, "
                          f"no <urlset>/<sitemapindex>)")
        for w in want:
            if w in body:
                found.add(w)
    return {i: i.lower().encode() not in found for i in ids}
