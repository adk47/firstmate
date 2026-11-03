"""Link replies: a customer who answers a proof ask with a URL instead of a file (r5 COPY RULING
fable-copy-1101-r5/r1-link).

A link is NOT a document of record. It never becomes a `proof_intake` row: 18 readers treat every
proof_intake row as a document on file (a document on file excludes the user from every ask; R1 counts
it as received). Links go to their own table, `proof_link_intake` (store.py), which no existing reader
sees; only the coded `status-doc-received --copy link` class reads it.

This module does three things, all coded, none judged:
- `customer_links`: every http(s) URL in a customer/lead/contact part (Intercom attachment hosts excluded:
  those are files and are filed as documents);
- `classify`: the host class from ONE policy file (policies/proof-link-hosts.json):
  outside_source (an allowlisted outside source) | muso (Muso's own pages) | unknown (shortener, unparseable,
  anything else). The class is the host's, never the page's content;
- `fetch`: a bounded, SSRF-safe GET of an outside_source link ONLY (https; resolved IPs all public; the
  connection is pinned to the checked IP; redirects followed only within the same allowlist entry; 10 s;
  2 MB). It records status, final host, sha256 and title; the body is never kept. muso and unknown hosts are
  never fetched.
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
import ssl
import urllib.parse
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

POLICY = os.path.join(os.path.dirname(__file__), "..", "..", "..", "policies", "proof-link-hosts.json")
FETCH_TIMEOUT_S = 10
FETCH_MAX_BYTES = 2 * 1024 * 1024
MAX_REDIRECTS = 3
CUSTOMER_AUTHORS = ("user", "lead", "contact")
_HREF = re.compile(r"""href\s*=\s*["']([^"']+)["']""", re.IGNORECASE)
_BARE = re.compile(r"""https?://[^\s<>"']+""", re.IGNORECASE)
_TITLE = re.compile(rb"<title[^>]*>(.*?)</title>", re.IGNORECASE | re.DOTALL)
_TRAIL = ".,;:!?)]}'\""


@dataclass(frozen=True)
class Policy:
    outside_source: tuple[str, ...]
    muso: tuple[str, ...]
    shorteners: tuple[str, ...]
    skip: tuple[str, ...]          # hosts that are never a link reply (Intercom's own attachment/CDN hosts)


def load_policy(path: str = POLICY) -> Policy:
    """The one host policy. Raises when it is missing or names no outside source: an empty allowlist would
    quietly turn every link into `unknown`, which is safe but hides a broken deploy."""
    with open(path, encoding="utf-8") as fh:
        d = json.load(fh)
    def hosts(key: str) -> tuple[str, ...]:
        out = []
        for e in d.get(key) or []:
            h = str(e.get("host") if isinstance(e, dict) else e).strip().lower().lstrip(".")
            if h:
                out.append(h)
        return tuple(out)
    pol = Policy(hosts("outside_source"), hosts("muso"), hosts("shorteners"), hosts("skip"))
    if not pol.outside_source:
        raise ValueError(f"{path}: no outside_source hosts")
    return pol


def _under(host: str, entry: str) -> bool:
    """host IS entry or a subdomain of it (never a suffix trick: 'eviltidal.com' is not under 'tidal.com')."""
    return host == entry or host.endswith("." + entry)


def normalise(url: str) -> str | None:
    """A stable key for one link: scheme + lower-cased host (+ non-default port) + path + query; the fragment
    and trailing punctuation dropped. None when it is not an http(s) URL with a host."""
    u = html.unescape(url).strip().rstrip(_TRAIL)
    try:
        p = urllib.parse.urlsplit(u)
        port = p.port
    except ValueError:
        return None
    if p.scheme.lower() not in ("http", "https") or not p.hostname:
        return None
    host = p.hostname.lower().rstrip(".")
    netloc = host if port in (None, 80 if p.scheme.lower() == "http" else 443) else f"{host}:{port}"
    return urllib.parse.urlunsplit((p.scheme.lower(), netloc, p.path or "/", p.query, ""))


def host_of(url: str) -> str:
    return (urllib.parse.urlsplit(url).hostname or "").lower().rstrip(".")


def customer_links(conv: dict[str, Any], policy: Policy) -> list[dict[str, Any]]:
    """Every distinct http(s) link a customer posted in this conversation, in order: {url (normalised),
    part_id, received_at (epoch)}. Links on skip hosts (Intercom's attachment/CDN hosts) are files, not
    link replies, and are left out. Staff/bot parts are never read."""
    source = conv.get("source") or {}
    parts = [dict(source, id=source.get("id") or "source", created_at=conv.get("created_at"))] + \
        list(((conv.get("conversation_parts") or {}).get("conversation_parts")) or [])
    out: list[dict[str, Any]] = []
    seen: set[str] = set()
    for p in parts:
        if (p.get("author") or {}).get("type") not in CUSTOMER_AUTHORS:
            continue
        body = str(p.get("body") or "")
        raw = _HREF.findall(body) + _BARE.findall(re.sub(r"<[^>]+>", " ", body))
        for r in raw:
            n = normalise(r)
            if not n or n in seen:
                continue
            h = host_of(n)
            if any(_under(h, s) for s in policy.skip):
                continue
            seen.add(n)
            out.append({"url": n, "part_id": str(p.get("id") or ""), "received_at": p.get("created_at")})
    return out


def classify(url: str, policy: Policy) -> tuple[str, str]:
    """(host_class, why). outside_source only for an allowlisted host over http(s); a shortener is unknown even
    when it would redirect to an allowlisted host (we never follow it to find out)."""
    n = normalise(url)
    if n is None:
        return "unknown", "unparseable"
    h = host_of(n)
    try:
        ipaddress.ip_address(h)
        return "unknown", "ip_literal"
    except ValueError:
        pass
    if any(_under(h, s) for s in policy.shorteners):
        return "unknown", "shortener"
    for m in policy.muso:
        if _under(h, m):
            return "muso", f"muso:{m}"
    for e in policy.outside_source:
        if _under(h, e):
            return "outside_source", f"allowlist:{e}"
    return "unknown", "other"


# ── fetch (outside_source only) ─────────────────────────────────────────────
Resolver = Callable[[str], list[str]]


def resolve_public(host: str) -> list[str]:
    """Every address `host` resolves to; raises when any one is not globally routable (private, loopback,
    link-local, reserved, multicast) so a public name pointing inside is never connected to."""
    addrs = sorted({ai[4][0] for ai in socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)})
    if not addrs:
        raise OSError("no address")
    for a in addrs:
        if not ipaddress.ip_address(a).is_global:
            raise PermissionError(f"non-public address for {host}")
    return addrs


class _PinnedHTTPS(http.client.HTTPSConnection):
    """An HTTPS connection to `host` made to an address we already checked (no second DNS lookup between the
    check and the connect); TLS still verifies the certificate for `host`."""

    def __init__(self, host: str, ip: str, timeout: float):
        super().__init__(host, 443, timeout=timeout, context=ssl.create_default_context())
        self._ip = ip

    def connect(self) -> None:
        sock = socket.create_connection((self._ip, 443), self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


def _get(url: str, ip: str) -> tuple[int, str | None, bytes, bool]:
    p = urllib.parse.urlsplit(url)
    path = urllib.parse.urlunsplit(("", "", p.path or "/", p.query, ""))
    conn = _PinnedHTTPS(p.hostname or "", ip, FETCH_TIMEOUT_S)
    try:
        conn.request("GET", path, headers={"User-Agent": "muso-proof-link-check/1", "Accept": "text/html,*/*"})
        resp = conn.getresponse()
        body = resp.read(FETCH_MAX_BYTES + 1)
        return resp.status, resp.getheader("Location"), body[:FETCH_MAX_BYTES], len(body) > FETCH_MAX_BYTES
    finally:
        conn.close()


Getter = Callable[[str, str], tuple[int, "str | None", bytes, bool]]


def fetch(url: str, policy: Policy, *, resolver: Resolver = resolve_public, getter: Getter = _get) -> dict[str, Any]:
    """The fetch result for an outside_source link: {fetch_status: ok | http_<n> | refused:<why> | error:<type>,
    http_status, final_host, sha256, bytes, truncated, title}. Never raises; never fetches a non-allowlisted
    host (refused:not_allowlisted), plain http (refused:not_https) or a redirect off the link's own allowlist
    entry (refused:redirect_off_entry)."""
    cls, why = classify(url, policy)
    if cls != "outside_source":
        return {"fetch_status": "refused:not_allowlisted"}
    entry = why.split(":", 1)[1]
    cur = normalise(url) or url
    for _hop in range(MAX_REDIRECTS + 1):
        if urllib.parse.urlsplit(cur).scheme != "https":
            return {"fetch_status": "refused:not_https"}
        host = host_of(cur)
        if not _under(host, entry):
            return {"fetch_status": "refused:redirect_off_entry", "final_host": host}
        try:
            ip = resolver(host)[0]
            status, loc, body, truncated = getter(cur, ip)
        except PermissionError:
            return {"fetch_status": "refused:non_public_address", "final_host": host}
        except Exception as exc:  # noqa: BLE001 - a failed fetch is a recorded fact, never a crash
            return {"fetch_status": f"error:{type(exc).__name__}", "final_host": host}
        if status in (301, 302, 303, 307, 308) and loc:
            cur = normalise(urllib.parse.urljoin(cur, loc)) or ""
            if not cur:
                return {"fetch_status": "refused:bad_redirect", "http_status": status, "final_host": host}
            continue
        m = _TITLE.search(body[:65536])
        title = html.unescape(m.group(1).decode("utf-8", "replace")).strip()[:200] if m else ""
        return {"fetch_status": "ok" if 200 <= status < 300 else f"http_{status}", "http_status": status,
                "final_host": host, "sha256": hashlib.sha256(body).hexdigest(), "bytes": len(body),
                "truncated": truncated, "title": re.sub(r"\s+", " ", title)}
    return {"fetch_status": "refused:too_many_redirects", "final_host": host_of(cur)}
