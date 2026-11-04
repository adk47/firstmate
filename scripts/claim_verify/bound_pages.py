"""Bound-page detection for profile claims: the ONE Python statement of which pages the catalog already
attributes to a profile (a "bound" page, where a claimant can place a one-time code that E1 then reads).

Ported 1:1 from core-backend `src/services/claiming/claimProofChallenge.js` (`hostAndPath`, `onHost`, the four
handle parsers and `surfacesFor(..., bound=true)`), and shared by every hydra reader that must agree with core
on it: the claim-status wave (credit_review.claim_status_list), the claims board, h2's audience files, and the
#1515 proof form's fixtures (Fable build-plan-1028 §2 (c)). Pure: no I/O.

A bound surface is `kind:id`:
  website link host        -> well_known:<host>, dns_txt:<host>, meta_tag:<host>
  Instagram link           -> instagram_bio:<handle>
  YouTube /channel/<id>    -> youtube_description:<id>
  Spotify raw profile      -> spotify_bio:<22-char id>
  YouTube Music raw profile-> youtube_description:<id>
X / TikTok are NOT bound pages: a post can only be read through a URL the claimant submits, which never
counts (core #10762 UNVERIFIABLE_KINDS). Their parsers stay here because core keeps them for claim-only links.

CLI (read-only): `python3 -m claim_verify.bound_pages < profile.json` prints the bound surfaces as JSON.
"""
from __future__ import annotations

import json
import re
import sys
from typing import Any
from urllib.parse import urlparse

SPOTIFY_ID = re.compile(r"^[0-9A-Za-z]{22}$")


def _host_path(url: Any) -> tuple[str, str] | None:
    if not url or not isinstance(url, str):
        return None
    raw = url if re.match(r"^[a-z][a-z0-9+.-]*://", url, re.I) else f"https://{url}"
    try:
        u = urlparse(raw)
    except ValueError:
        return None
    if u.scheme not in ("http", "https") or u.username or u.password or not u.hostname:
        return None
    host = u.hostname.lower()
    host = host[4:] if host.startswith("www.") else host
    return host.rstrip("."), (u.path or "/")


def _on(hp: tuple[str, str] | None, hosts: tuple[str, ...]) -> bool:
    return bool(hp) and any(hp[0] == h or hp[0].endswith("." + h) for h in hosts)


def registrable_host(url: Any) -> str | None:
    hp = _host_path(url)
    return hp[0] or None if hp else None


def instagram_handle(url: Any) -> str | None:
    hp = _host_path(url)
    if not _on(hp, ("instagram.com",)):
        return None
    m = re.match(r"^/@?([A-Za-z0-9_.]+)", re.sub(r"^/instagram\.com/", "/", hp[1], flags=re.I))
    if not m or m.group(1).lower() in ("p", "reel", "reels", "stories", "explore", "accounts"):
        return None
    return m.group(1).lower().rstrip(".")


def x_handle(url: Any) -> str | None:
    hp = _host_path(url)
    if not _on(hp, ("x.com", "twitter.com")):
        return None
    m = re.match(r"^/@?([A-Za-z0-9_]{1,15})(?:[/?#]|$)", hp[1])
    if not m or m.group(1).lower() in ("i", "home", "search", "explore", "intent", "share"):
        return None
    return m.group(1).lower()


def tiktok_handle(url: Any) -> str | None:
    hp = _host_path(url)
    if not _on(hp, ("tiktok.com",)):
        return None
    m = re.match(r"^/@([A-Za-z0-9_.]+)", hp[1])
    return m.group(1).lower().rstrip(".") if m else None


def youtube_channel_id(url: Any) -> str | None:
    hp = _host_path(url)
    if not _on(hp, ("youtube.com",)):
        return None
    m = re.match(r"^/channel/([A-Za-z0-9_-]{10,})", hp[1])
    return m.group(1) if m else None


def bound_surfaces(profile: dict[str, Any]) -> list[str]:
    """The catalog-attributed (bound) surfaces of a profile, as core surfacesFor() builds them."""
    links = profile.get("links") if isinstance(profile.get("links"), dict) else {}
    out: list[str] = []
    site = registrable_host(links.get("website"))
    if site:
        out += [f"well_known:{site}", f"dns_txt:{site}", f"meta_tag:{site}"]
    # X / TikTok posts are NOT bindable pages: they can only be read through a post URL the claimant submits,
    # which never counts (core #10762 UNVERIFIABLE_KINDS; QA on hydra #1406 @68159ae4).
    for kind, fn, key in (("instagram_bio", instagram_handle, "instagram"), ("youtube_description", youtube_channel_id, "youtube")):
        h = fn(links.get(key))
        if h:
            out.append(f"{kind}:{h}")
    for r in profile.get("rawProfiles") or []:
        if not isinstance(r, dict) or not r.get("id"):
            continue
        if r.get("source") == "spotify" and SPOTIFY_ID.match(str(r["id"])):
            out.append(f"spotify_bio:{r['id']}")
        if r.get("source") == "youtube_music":
            out.append(f"youtube_description:{r['id']}")
    return sorted(set(out))


def has_bound_page(profile: dict[str, Any]) -> bool:
    """True when the catalog attributes at least one bound page to the profile."""
    return bool(bound_surfaces(profile))


def main(stdin=sys.stdin, stdout=sys.stdout) -> int:
    doc = json.load(stdin)
    doc = doc.get("data", doc) if isinstance(doc, dict) else None
    if not isinstance(doc, dict):
        print("bound_pages: expected a profile JSON object", file=sys.stderr)
        return 2
    json.dump({"id": doc.get("id"), "bound": bound_surfaces(doc)}, stdout)
    stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
