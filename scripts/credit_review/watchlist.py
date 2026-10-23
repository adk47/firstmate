"""The fraud watchlist (policies/fraud-watchlist.json): one source of truth for actors whose
credit requests every automatic approval path HOLDS FOR REVIEW (captain 2026-10-22 20:15Z,
firstmate 154). Never a reject, never a removal.

``load(path)`` -> Watchlist(user_ids, profile_ids, fraud_user_ids, fraud_profile_ids, email
hashes, name hashes, domains). A present-but-malformed file is fatal (ValueError): a broken
watchlist must never read as "nobody is watched". ``required=True`` (the deployed default path)
makes a MISSING file fatal too.

Names and emails are matched by sha256 of the normalized value (``norm_name`` / ``norm_email``),
so the repo carries no named individuals in clear text.
"""
from __future__ import annotations

import hashlib
import json
import re
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT = Path(__file__).resolve().parents[2] / "policies" / "fraud-watchlist.json"
TIERS = ("fraud", "review")
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
# QA @1339: a domain entry flags EVERY address at it, so only organisation-specific domains are
# allowed. Shared mailbox providers and relays are refused (fatal), never matched.
SHARED_DOMAIN = re.compile(
    r"(^|\.)(gmail|googlemail|yahoo|ymail|hotmail|outlook|live|msn|icloud|me|mac|aol|proton|protonmail|pm|gmx|"
    r"mail|yandex|zoho|qq|163|126|naver|daum|web|t-online|orange|free|laposte|libero|virgilio|tiscali|seznam|"
    r"wp|o2|rambler|bk|inbox|list|uol|bol|terra|rediffmail|fastmail|tutanota|hey|duck|"
    r"privaterelay\.appleid|relay\.firefox|simplelogin|anonaddy|mozmail)\.[a-z.]+$")


def norm_name(s: str) -> str:
    s = unicodedata.normalize("NFKD", s or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "", s)


def norm_email(s: str) -> str:
    return (s or "").strip().lower()


def sha(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


@dataclass(frozen=True)
class Watchlist:
    user_ids: frozenset = field(default_factory=frozenset)
    profile_ids: frozenset = field(default_factory=frozenset)
    fraud_user_ids: frozenset = field(default_factory=frozenset)
    fraud_profile_ids: frozenset = field(default_factory=frozenset)
    email_sha256: frozenset = field(default_factory=frozenset)
    name_sha256: frozenset = field(default_factory=frozenset)
    email_domains: frozenset = field(default_factory=frozenset)

    def name_hit(self, name: str) -> bool:
        n = norm_name(name)
        return bool(n) and sha(n) in self.name_sha256

    def email_hit(self, email: str) -> bool:
        e = norm_email(email)
        return "@" in e and (sha(e) in self.email_sha256 or e.split("@", 1)[1] in self.email_domains)


def load(path: Path | str | None = None, *, required: bool | None = None) -> Watchlist:
    p = Path(path) if path else DEFAULT
    required = (p.resolve() == DEFAULT.resolve()) if required is None else required
    if not p.exists():
        if required:
            raise ValueError(f"fraud watchlist missing: {p}")
        return Watchlist()
    try:
        doc = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ValueError(f"fraud watchlist unreadable: {p}: {exc}") from exc
    entries = doc.get("entries") if isinstance(doc, dict) else None
    if not isinstance(entries, list):
        raise ValueError(f"fraud watchlist {p}: no entries list")
    sets: dict[str, set] = {k: set() for k in ("u", "p", "fu", "fp", "e", "n", "d")}
    for i, e in enumerate(entries):
        if not isinstance(e, dict) or e.get("tier") not in TIERS:
            raise ValueError(f"fraud watchlist {p}: entry {i} has no valid tier")
        for k in ("reason", "evidence", "added_at", "added_by"):
            if not str(e.get(k) or "").strip():
                raise ValueError(f"fraud watchlist {p}: entry {i} lacks {k}")
        users, profiles = e.get("user_ids") or [], e.get("profile_ids") or []
        if not all(isinstance(u, int) and not isinstance(u, bool) for u in users):
            raise ValueError(f"fraud watchlist {p}: entry {i} has a non-integer user id")
        if not all(isinstance(x, str) and UUID.match(x.strip().lower()) for x in profiles):
            raise ValueError(f"fraud watchlist {p}: entry {i} has a malformed profile id")
        if not users and not profiles:
            raise ValueError(f"fraud watchlist {p}: entry {i} names no user or profile")
        for key, field_name in (("e", "email_sha256"), ("n", "name_sha256")):
            vals = e.get(field_name) or []
            if not all(isinstance(v, str) and HEX64.match(v) for v in vals):
                raise ValueError(f"fraud watchlist {p}: entry {i} {field_name} must be sha256 hex")
            sets[key].update(vals)
        doms = [str(d).strip().lower() for d in (e.get("email_domains") or []) if str(d).strip()]
        shared = [d for d in doms if SHARED_DOMAIN.search(d)]
        if shared:
            raise ValueError(f"fraud watchlist {p}: entry {i} lists shared mail domains {shared} "
                             "(they would flag unrelated people; use email_sha256)")
        sets["d"].update(doms)
        sets["u"].update(users)
        sets["p"].update(x.strip().lower() for x in profiles)
        if e["tier"] == "fraud":
            sets["fu"].update(users)
            sets["fp"].update(x.strip().lower() for x in profiles)
    return Watchlist(frozenset(sets["u"]), frozenset(sets["p"]), frozenset(sets["fu"]), frozenset(sets["fp"]),
                     frozenset(sets["e"]), frozenset(sets["n"]), frozenset(sets["d"]))
