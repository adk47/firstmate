"""Read-only I/O for the pipeline: ClickUp, Intercom, the core replica (Trino), the admin catalog, the hide lists.

Every read FAILS CLOSED (c3 design §3): a failed read raises `Unknown`; the caller records nothing for that row
and exits non-zero. A green run that silently covered nothing is the failure this forbids. Nothing here writes.
"""
from __future__ import annotations

import csv
import html
import io
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]          # scripts/
sys.path.insert(0, str(HERE))

from gdpr_pipeline.identity import Page             # noqa: E402

TRINO = os.environ.get("GDPR_TRINO", "/opt/hydra/scripts/trino-query.sh")
INTERCOM = "https://api.intercom.io"
CLICKUP_LIST = "901000600160"
HDEVOPS_REPO = "Muso-AI/H-DevOps"
HDEVOPS_FILES = ("k8s/prod/core-services/deployments.yaml", "k8s/dev/dev-deployments.yaml")
PDP_REPO = "Muso-AI/platform-data-processing"
PDP_LIST = "src/tools/jobs/industry_processing/drivers/calc/sitemap/legal_hidden.py"
PDP_TEST = "tests/unit/test_sitemap_legal_hidden.py"
UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


class Unknown(RuntimeError):
    """A read that did not complete. Never a verdict."""


# ---- core replica

WIDE_FIELD_BYTES = 64 * 1024 * 1024


def trino(sql: str, field_limit: int = 0) -> list[list[str]]:
    """Rows of one replica read. A field wider than the CSV reader takes is `Unknown`, never a short row and never a
    raw `csv.Error`: every caller's "could not read" path catches `Unknown`. `field_limit` raises the reader's limit
    for this one read and puts it back (the limit is process-wide)."""
    try:
        p = subprocess.run([TRINO], input=sql, capture_output=True, text=True, timeout=300, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        raise Unknown(f"replica read did not run: {type(exc).__name__}") from exc
    if p.returncode:
        raise Unknown(f"replica read failed: {p.stderr.strip()[-200:]}")
    text = "\n".join(ln for ln in p.stdout.splitlines() if ln.startswith('"'))
    before = csv.field_size_limit(field_limit) if field_limit else None
    try:
        return list(csv.reader(io.StringIO(text)))
    except csv.Error as exc:
        raise Unknown("replica read returned a field wider than the reader takes") from exc
    finally:
        if before is not None:
            csv.field_size_limit(before)


def trino_wide(sql: str) -> list[list[str]]:
    """`trino` for a read that must return whole values however long they are (the Art. 15 copy: a truncated or
    dropped field is a copy that is not the data). Found on the live replica 2026-11-12: `user_action_log` holds
    values past the reader's default 131,072 characters."""
    return trino(sql, field_limit=WIDE_FIELD_BYTES)


def _q(xs) -> str:
    return ",".join("'" + str(x).replace("'", "''") + "'" for x in xs)


# The keys of `claiming.verificationlinks` that hold a LINK (measured on the replica 2026-11-13: every processed
# claim of the last 30 days is NULL, {facebook, instagram, twitter, weblinks}, or {email, role[, instagram,
# weblink]}). `email` and `role` say who filed a company claim; they are not a link to anything.
CLAIM_LINK_KEYS = ("facebook", "instagram", "twitter", "weblinks", "weblink")


class Claims(dict):
    """{profile id: accounts holding a PROCESSED, not deleted claim}, plus `.links`: the verification links each of
    those claims was filed with, `{profile id: {account id: (link, ...)}}`. One read answers both, so the two can
    never disagree. A plain dict has no `.links`, and every reader treats that as "no link to compare": absent is
    never a pass. A claim is evidence only when one of its links names a surface the profile itself carries,
    matched by `link_matches_profile`."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.links: dict[str, dict[int, tuple[str, ...]]] = {}


@dataclass(frozen=True)
class ProfileIdentity:
    """The artist ids and social handles the catalog attributes to ONE page. A claim link is evidence only when it
    names one of these; a link to any other page is not a tie to this profile (ruling 2026-11-14)."""

    spotify: frozenset[str] = frozenset()
    apple: frozenset[str] = frozenset()
    social: frozenset[tuple[str, str]] = frozenset()

    def __bool__(self) -> bool:
        return bool(self.spotify or self.apple or self.social)


# An artist id, in the two shapes a claim or a profile names one. Both are matched on the id alone: a page URL can
# be dressed with an `intl-xx` segment or a locale and an artist name, and none of that changes whose page it is.
SPOTIFY_ARTIST = re.compile(r"^/(?:intl-[a-z-]+/)?artist/([0-9A-Za-z]{22})(?:[/?#]|$)", re.I)
APPLE_ARTIST = re.compile(r"^/(?:[a-z]{2}/)?artist/(?:[^/]+/)?(\d+)(?:[/?#]|$)", re.I)
# A social profile: the network plus the handle of an ACCOUNT's own URL. x.com and twitter.com are one network;
# www. and m. are the same host. Only the account shapes count - `/shorts/<video>`, `/groups/<group>`,
# `/watch` and the like are other people's pages, and reading their first path segment as a handle would tie two
# unrelated links to one account (QA on hydra #1963).
SOCIAL_HOSTS = {"instagram.com": "instagram", "facebook.com": "facebook", "fb.com": "facebook",
                "twitter.com": "twitter", "x.com": "twitter", "tiktok.com": "tiktok",
                "youtube.com": "youtube", "youtu.be": "youtube"}
# A one-segment URL on these networks is a handle, unless it is one of the network's own section, navigation or
# content roots (`/photo/?fbid=`, `/i/...`, `/settings`): those are the same word on every account, so reading one
# as a handle would match two unrelated links. The list is a tripwire for the common ones and can never be
# complete; `SOCIAL_HANDLE` below is the rule (a `.php` endpoint is never a handle), and a miss still needs the
# catalog's OWN profile link to be that same non-account page.
SOCIAL_NOT_HANDLES = frozenset({
    # shared
    "home", "search", "explore", "login", "logout", "signup", "settings", "notifications", "messages", "about",
    "help", "privacy", "terms", "tos", "legal", "policies", "share", "sharer", "intent", "hashtag", "live",
    # instagram
    "p", "reel", "reels", "stories", "accounts", "direct", "tv", "tags", "locations", "directory", "developer",
    # facebook
    "groups", "events", "marketplace", "gaming", "friends", "watch", "photo", "photos", "video", "videos",
    "posts", "pages", "pg", "people", "public", "notes", "places", "saved", "memories", "bookmarks", "me",
    "dialog", "plugins", "business", "ads", "jobs", "games", "fundraisers", "offers", "media",
    # twitter / x
    "i", "compose", "lists", "topics", "communities", "account", "download", "who_to_follow",
    # youtube / tiktok roots, should a looser shape ever reach here
    "playlist", "results", "shorts", "post", "feed", "embed", "channel", "user", "c", "t", "tag", "discover",
    "foryou", "following"})
# What a handle can look like on any of them. A dotted `.php` endpoint (`photo.php`, `story.php`, `profile.php`)
# fits the letters and is refused by name.
SOCIAL_HANDLE = re.compile(r"[a-z0-9_][a-z0-9._-]{0,99}")


def _url_parts(url: str) -> tuple[str, str] | None:
    raw = url.strip()
    if not re.match(r"^[a-z][a-z0-9+.-]*://", raw, re.I):
        raw = "https://" + raw
    try:
        u = urllib.parse.urlparse(raw)
    except ValueError:
        return None
    if u.scheme.lower() not in ("http", "https") or not u.hostname:
        return None
    host = u.hostname.lower().rstrip(".")
    if host.startswith("www."):
        host = host[4:]
    if host.startswith("m."):
        host = host[2:]
    return host, u.path or "/"


def _artist_id(url: str) -> tuple[str, str] | None:
    parts = _url_parts(url)
    if not parts:
        return None
    host, path = parts
    if host == "open.spotify.com":
        m = SPOTIFY_ARTIST.match(path)
        return ("spotify", m.group(1)) if m else None
    if host == "music.apple.com":
        m = APPLE_ARTIST.match(path)
        return ("apple", m.group(1)) if m else None
    return None


def _social(url: str) -> tuple[str, str] | None:
    parts = _url_parts(url)
    if not parts:
        return None
    network = SOCIAL_HOSTS.get(parts[0])
    if not network:
        return None
    segments = [s for s in parts[1].split("/") if s]
    if not segments:
        return None
    if network == "youtube":
        # a channel's own forms only: /@handle, /channel/<id>, /user/<name>, /c/<name>
        if not segments[0].startswith("@"):
            if len(segments) < 2 or segments[0].lower() not in ("channel", "user", "c"):
                return None
            segments = segments[1:]
    elif network == "tiktok":
        if not segments[0].startswith("@"):
            return None
    elif len(segments) != 1:
        # instagram / facebook / twitter: the account is the whole path, so a deeper path is a
        # content or navigation page (`/groups/<g>`, `/shorts/<v>`, `/handle/reels`, ...)
        return None
    handle = segments[0].lstrip("@").lower().rstrip(".")
    if not SOCIAL_HANDLE.fullmatch(handle) or handle.endswith(".php") or handle in SOCIAL_NOT_HANDLES:
        return None
    return network, handle


def profile_identity(doc: dict | None) -> ProfileIdentity:
    """The surfaces the catalog itself attributes to the page: its Spotify / Apple artist id, and the handle of each
    social account it links. A profile that could not be read, or carries none of these, is an EMPTY identity - and
    an empty identity matches nothing, so the requester is asked rather than passed."""
    if not isinstance(doc, dict):
        return ProfileIdentity()
    spotify, apple, social = set(), set(), set()
    sid = doc.get("spotifyId")
    if isinstance(sid, str) and re.fullmatch(r"[0-9A-Za-z]{22}", sid.strip()):
        spotify.add(sid.strip())
    raws = doc.get("rawProfiles")
    for raw in raws if isinstance(raws, list) else []:
        if not isinstance(raw, dict):
            continue
        url = raw.get("url")
        found = _artist_id(url) if isinstance(url, str) else None
        if found:
            (spotify if found[0] == "spotify" else apple).add(found[1])
        source, rid = str(raw.get("source") or "").lower(), raw.get("id")
        if isinstance(rid, str) and re.fullmatch(r"\d+", rid.strip()):
            if source in ("apple", "apple_music"):
                apple.add(rid.strip())
        if isinstance(rid, str) and source == "spotify" and re.fullmatch(r"[0-9A-Za-z]{22}", rid.strip()):
            spotify.add(rid.strip())
    links = doc.get("links") if isinstance(doc.get("links"), dict) else {}
    for value in links.values():
        for item in (value if isinstance(value, list) else [value]):
            if isinstance(item, str):
                found = _social(item)
                if found:
                    social.add(found)
    return ProfileIdentity(frozenset(spotify), frozenset(apple), frozenset(social))


def _claim_link_tokens(links_json: str) -> tuple[str, ...]:
    try:
        doc = json.loads(links_json) if links_json else None
    except ValueError:
        return ()
    return claim_link_tokens(doc)


def claim_link_tokens(doc) -> tuple[str, ...]:
    """Every link a claim's `verificationlinks` document carries, one token each. The ONE reader of that document:
    the identity step (`processed_claims`) and the hide guard (`hide_guard.reviewed`) both match these tokens with
    `link_matches_profile`, so the two cannot disagree about what a claim offers as evidence."""
    if not isinstance(doc, dict):
        return ()
    out = []
    for key in CLAIM_LINK_KEYS:
        value = doc.get(key)
        for item in (value if isinstance(value, list) else [value]):
            if isinstance(item, str):
                out.extend(t.strip("()<>[]\"'") for t in re.split(r"[\s,;]+", item) if t.strip("()<>[]\"'"))
    return tuple(out)


def link_matches_profile(link: str, identity: ProfileIdentity) -> bool:
    """One claim link names this profile: the same Spotify / Apple artist id, or the same network and handle as a
    social account the profile links. Deliberately NOT a website host, a search result or any other page-shaped
    link: those say someone posted a URL, not that the page is the requester's."""
    if not identity:
        return False
    found = _artist_id(link)
    if found and ((found[0] == "spotify" and found[1] in identity.spotify)
                  or (found[0] == "apple" and found[1] in identity.apple)):
        return True
    social = _social(link)
    return bool(social and social in identity.social)


def processed_claims(profile_ids: list[str]) -> Claims:
    """{profile id: accounts holding a PROCESSED, not deleted claim}, whether the target is the claim's main profile
    or one of its `extraprofileids`. A claim that carries the target only as an extra still means the requester owns
    that page; dropping it would send a rightful claim down the ASK_IDENTITY road.

    `.links` on the answer is each such claim's verification links, for a reader that holds the profile document
    (`page_facts`) to compare with the surfaces the catalog attributes to that page. The `updatedat > createdat`
    rule of ruling 2026-11-13 lives here, at the read: a claim processed the moment it was made carries no links
    for any later reader, so a dead second copy of the rule cannot drift from what is executed."""
    ids = sorted({p for p in profile_ids if UUID_RE.fullmatch(p)})
    out = Claims({p: set() for p in ids})
    out.links = {p: {} for p in ids}
    for i in range(0, len(ids), 150):
        chunk = ids[i:i + 150]
        # extraprofileids is a varchar whose exact shape (JSON array, comma list, brace list) is not guaranteed, so
        # match with strpos on the raw text and confirm the uuid in Python rather than trusting a cast.
        extra = " OR ".join(f"strpos(lower(CAST(extraprofileids AS varchar)), '{p.lower()}') > 0" for p in chunk)
        # verificationlinks is a JSON column: a CAST to varchar fails on an object, json_format does not.
        for pid, uid, ex, links, later in trino(
                "SELECT CAST(profileid AS varchar), CAST(userid AS varchar), CAST(extraprofileids AS varchar), "
                "json_format(verificationlinks), CAST(updatedat > createdat AS varchar) "
                "FROM postgresql_core.public.claiming "
                f"WHERE (CAST(profileid AS varchar) IN ({_q(chunk)}) OR {extra}) AND userid IS NOT NULL "
                "AND deletedat IS NULL AND lower(CAST(status AS varchar)) = 'processed'"):
            if not uid.isdigit():
                continue
            tokens = _claim_link_tokens(links) if later == "true" else ()
            low = (ex or "").lower()
            for target in dict.fromkeys([pid] + [t for t in chunk if t.lower() in low]):
                if target in out:
                    out[target].add(int(uid))
                    if tokens:
                        seen = out.links[target].get(int(uid), ())
                        out.links[target][int(uid)] = tuple(dict.fromkeys(seen + tokens))
    return out


def _width(n: int, rows: list[list[str]]) -> list[list[str]]:
    """The rows, when every one has `n` fields. A short or long row is a read that did not come back whole (a value
    with a line break is cut by the line filter in `trino`), so it is `Unknown`, never a row to decide on."""
    for r in rows:
        if len(r) != n:
            raise Unknown(f"replica read returned a row of {len(r)} fields where {n} were asked for")
    return rows


def claim_proofs(profile_ids: list[str]) -> dict[str, list[dict]]:
    """{profile id: every PROCESSED, not deleted claim on it} with what the hide guard needs to weigh one:
    {"claim_id", "account", "reason", "links" (the claimant's verification links, parsed), "created" (epoch s),
    "processed_later" (True only when the replica states `updatedat > createdat`: the claim was processed after it
    was made, the same fact `processed_claims` requires before a link is evidence; anything else is False)}.

    `processed_claims` answers "who holds a claim"; this answers "what kind of claim". Measured 2026-11-13: 5,217 of
    6,189 claims processed in 30 days carry reason 'created by user', no links, and were processed the second they
    were filed. The links are the claimant's own social and web addresses: they are returned to the guard and must
    never be printed or logged."""
    ids = sorted({p for p in profile_ids if UUID_RE.fullmatch(p)})
    out: dict[str, list[dict]] = {p: [] for p in ids}
    for i in range(0, len(ids), 150):
        chunk = ids[i:i + 150]
        extra = " OR ".join(f"strpos(lower(CAST(extraprofileids AS varchar)), '{p.lower()}') > 0" for p in chunk)
        for cid, pid, uid, ex, reason, links, created, later in _width(8, trino(
                "SELECT CAST(id AS varchar), CAST(profileid AS varchar), CAST(userid AS varchar), "
                "CAST(extraprofileids AS varchar), CAST(reason AS varchar), json_format(verificationlinks), "
                "CAST(CAST(to_unixtime(createdat) AS bigint) AS varchar), CAST(updatedat > createdat AS varchar) "
                "FROM postgresql_core.public.claiming "
                f"WHERE (CAST(profileid AS varchar) IN ({_q(chunk)}) OR {extra}) AND userid IS NOT NULL "
                "AND deletedat IS NULL AND lower(CAST(status AS varchar)) = 'processed'")):
            if not uid.isdigit() or not created.lstrip("-").isdigit():
                raise Unknown(f"claim {cid}: the replica did not state the account or the filing time")
            try:
                parsed = json.loads(links) if links else None
            except ValueError as exc:
                raise Unknown(f"claim {cid}: verification links are not JSON") from exc
            claim = {"claim_id": cid, "account": int(uid), "reason": reason or "", "links": parsed,
                     "created": int(created), "processed_later": later == "true"}
            low = (ex or "").lower()
            for target in chunk:
                if target == pid or target.lower() in low:
                    out[target].append(claim)
    return out


def profile_sources(profile_ids: list[str]) -> dict[str, dict]:
    """{profile id: {"raws": the profile's sources as 'muso:<id>', 'tidal:<id>', ..., "created": epoch s,
    "identity": the artist ids and social handles the profile itself names (`profile_identity`)}} from the live
    admin profile. A profile core does not return is absent from the answer: "not read" is the caller's to
    refuse, never an empty source list.

    Not the catalog view: on 2026-11-13 its newest profile was four days old, so it lacked 782 of 5,214 new
    profiles and would not have shown a merge made since."""
    from datetime import datetime, timezone
    out: dict[str, dict] = {}
    for pid in sorted({p for p in profile_ids if UUID_RE.fullmatch(p)}):
        doc = profile_doc(pid)
        if not doc:
            continue
        raws, created = doc.get("rawProfiles"), doc.get("createdAt")
        if not isinstance(raws, list) or not all(isinstance(x, dict) and isinstance(x.get("source"), str)
                                                 and x["source"] for x in raws):
            raise Unknown(f"admin profile {pid}: the answer did not state the profile's sources")
        try:
            at = datetime.fromisoformat(created.replace("Z", "+00:00"))
        except (AttributeError, ValueError) as exc:
            raise Unknown(f"admin profile {pid}: the answer did not state when the profile was created") from exc
        if at.tzinfo is None:
            at = at.replace(tzinfo=timezone.utc)
        out[pid] = {"raws": [f"{x['source']}:{x.get('id') or ''}" for x in raws], "created": int(at.timestamp()),
                    "identity": profile_identity(doc)}
    return out


def profile_sites(profile_ids: list[str]) -> dict[str, str]:
    """{profile id: the website on the live admin profile, '' when it has none}. A profile core does not return is
    absent from the answer. No website stated is '' on purpose: for the one reader (the hide guard, path D) an
    empty website holds the page, so absence can only refuse a hide, never allow one."""
    out: dict[str, str] = {}
    for pid in sorted({p for p in profile_ids if UUID_RE.fullmatch(p)}):
        doc = profile_doc(pid)
        if not doc:
            continue
        links = doc.get("links")
        site = links.get("website") if isinstance(links, dict) else None
        if (links is not None and not isinstance(links, dict)) or (site is not None and not isinstance(site, str)):
            raise Unknown(f"admin profile {pid}: the answer did not state the profile's website as text")
        out[pid] = site or ""
    return out


def account_names(uids: list[int]) -> dict[int, tuple[str, ...]]:
    ids = sorted({int(u) for u in uids})
    out: dict[int, tuple[str, ...]] = {}
    for i in range(0, len(ids), 500):
        for uid, fn, ln, full in trino("SELECT CAST(id AS varchar), firstname, lastname, fullname FROM "
                                       f"postgresql_core.public.users WHERE id IN ({','.join(map(str, ids[i:i+500]))})"):
            names = tuple(n for n in {f"{fn or ''} {ln or ''}".strip(), (full or "").strip()} if n)
            out[int(uid)] = names
    return out


def account_email(uid: int) -> str:
    """The sign-in address on the account right now. Raises Unknown unless exactly one account row answers: the
    address a copy of personal data is sent to is never a guess."""
    rows = trino(f"SELECT email FROM postgresql_core.public.users WHERE id = {int(uid)}")
    if len(rows) != 1 or len(rows[0]) != 1:
        raise Unknown(f"{len(rows)} account row(s) for one account id")
    return (rows[0][0] or "").strip()


def accounts_by_email(email: str) -> list[int]:
    if not email:
        return []
    return sorted({int(u) for (u,) in trino("SELECT CAST(id AS varchar) FROM postgresql_core.public.users "
                                             f"WHERE lower(email) = {_q([email.lower()])}") if u.isdigit()})


def resolve_account(external_id: str, email: str, email_trusted: bool) -> tuple[int | None, str]:
    """(account id, how) -- identity_resolver r5 on the contact's external_id first (the one resolver the verify
    gate uses); else, only when the address was delivered by mail or is an identified Intercom user, the ONE
    account whose sign-in email it is. Two accounts or none -> None (never a guess)."""
    from credit_review import identity_resolver
    if external_id:
        res = identity_resolver.resolve([external_id], trino).get(external_id)
        if res and res.account_id is not None:
            return res.account_id, f"external_id ({res.matched_by})"
    if email and email_trusted:
        acc = accounts_by_email(email)
        if len(acc) == 1:
            return acc[0], "account email"
    return None, ""


# ---- catalog

def profile_doc(pid: str) -> dict | None:
    """The admin profile (GET only). None on 404 (which core also answers on a failed catalog read)."""
    from credit_review import admin
    try:
        return admin.profile(admin.AdminClient(), pid)
    except admin.NotFound:
        return None
    except admin.AdminError as exc:
        raise Unknown(f"admin profile {pid}: {exc}") from exc


DELETED_READ_CHUNK = 20


def profiles_deleted(ids: list[str]) -> dict[str, bool]:
    """{profile id: is it DELETED and not merged} for every id asked, read now from the admin API (GET only).

    True needs the record itself to say so: the profile is returned by the include-deleted read, carries a `deleted`
    stamp and has no `merged` record. A merged profile is not gone (its content lives on under the survivor), a live
    one is not gone, and an id the read does not return at all proves nothing, so each of those is False. A read
    that fails raises: "could not read" is never "deleted" (the final letter for a page already off the site states
    this as a fact, `Run.gone_now`). Measured 2026-11-15 on the 48 pages of the 49 open all-GONE erasure requests:
    48 returned, 48 deleted, 0 merged."""
    from credit_review import admin
    want = sorted({str(i).lower() for i in ids if i})
    out = {i: False for i in want}
    client = admin.AdminClient()
    for at in range(0, len(want), DELETED_READ_CHUNK):
        chunk = want[at:at + DELETED_READ_CHUNK]
        qs = "&".join(["includeDeleted=true", f"limit={len(chunk)}"] + [f"ids={i}" for i in chunk])
        try:
            body = client.get(f"/admin/profile?{qs}")
        except admin.AdminError as exc:
            raise Unknown(f"admin profile list (deleted read, {len(chunk)} ids): {exc}") from exc
        items = body.get("items") if isinstance(body, dict) else None
        if not isinstance(items, list):
            raise Unknown("admin profile list (deleted read): the answer carries no item list")
        for item in items:
            pid = str((item or {}).get("id") or "").lower()
            if pid in out:
                out[pid] = bool(item.get("deleted")) and not item.get("merged")
    return out


def public_status(entity: str, pid: str) -> int:
    """The public status code. 404 is an ANSWER; 5xx (and 429) are NOT: a page we could not read must never read
    as "not found" and settle as gone/UNKNOWN, so they raise and the run exits 2."""
    req = urllib.request.Request(f"https://muso.ai/{entity}/{pid}", headers={"User-Agent": "muso-gdpr-pipeline"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            if r.status >= 500:
                raise Unknown(f"public GET {entity}/{pid}: HTTP {r.status}")
            return r.status
    except urllib.error.HTTPError as exc:
        if exc.code >= 500 or exc.code == 429:
            raise Unknown(f"public GET {entity}/{pid}: HTTP {exc.code}")
        return exc.code
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise Unknown(f"public GET {entity}/{pid}: {exc}") from exc


def resolve_prefixes(prefixes: list[str]) -> dict[str, str]:
    """{8-char prefix: full profile id} for prefixes that match EXACTLY one catalog profile (legal-intake and the
    markdown register keep prefixes only). Ambiguous or absent prefixes are left out (-> UNKNOWN, never a guess)."""
    pre = sorted({p for p in prefixes if re.fullmatch(r"[0-9a-f]{8}", p)})
    hits: dict[str, set[str]] = {p: set() for p in pre}
    for i in range(0, len(pre), 60):
        cond = " OR ".join(f"CAST(profile_id AS varchar) LIKE '{p}%'" for p in pre[i:i + 60])
        for (pid,) in trino(f"SELECT CAST(profile_id AS varchar) FROM postgresql_catalog.public.catalog_profile WHERE {cond}"):
            if pid[:8] in hits:
                hits[pid[:8]].add(pid.lower())
    return {p: next(iter(v)) for p, v in hits.items() if len(v) == 1}


def _is_number(v) -> bool:
    """A JSON number, and NOT a bool (bool is an int subclass: `True` would have read as 1 credit)."""
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def half_hidden(hd: set[str], pdp: set[str]) -> dict[str, str]:
    """{id: "hd"|"pdp"} for ids that exactly ONE of the two hide lists holds.

    A hide needs both (the app-side hide and the sitemap 410), and they ship in separate PRs, so this map names the
    window in which a hide is half applied. Without it the page reads as 404 everywhere and the identity pass files it
    as GONE - "deleted outside the hide process" - which is our own unfinished work, not somebody else's deletion.
    """
    return {**{i: "hd" for i in hd - pdp}, **{i: "pdp" for i in pdp - hd}}


ITEM_ENTITIES = ("track", "album")
ITEM_MAX_ARTISTS = 8        # more artists than this is a compilation: a person's call, and not worth 8+ reads a tick


def item_doc(entity: str, pid: str) -> dict | None:
    """The admin track / album (GET only). None on 404. Same contract as `profile_doc`: a read that did not complete
    raises Unknown and is never an answer."""
    from credit_review import admin
    if entity not in ITEM_ENTITIES:
        raise Unknown(f"item_doc: {entity!r} is not a track or an album")
    try:
        doc = admin.AdminClient().get(f"/admin/{entity}/{pid}")
    except admin.NotFound:
        return None
    except admin.AdminError as exc:
        raise Unknown(f"admin {entity} {pid}: {exc}") from exc
    return doc if isinstance(doc, dict) else None


def item_page(entity: str, pid: str, half_hidden: str = "") -> Page:
    """The facts the item gate needs about ONE track / album: its own popularity and its artists' PROFILE facts.

    Everything here comes from the catalog. The artist ids are the item's `artists[].id`; each artist is then read as
    a profile with the same reader and the same typed-field rule a profile page gets, and its processed claims come
    from the same claiming table. The artist page deliberately carries NO hide-list state: an artist who is already
    hidden is still the person the requester has to be.

    A shape the gate cannot use (no such item, `artists` not a list of ids, popularity not a number, too many
    artists) returns an unread item with the reason, which `identity.decide_item` keeps with a person."""
    def unread(why: str) -> Page:
        return Page(pid, entity, half_hidden=half_hidden, item_why=f"{entity} page: {why}; a person decides the scope")

    if not UUID_RE.fullmatch(pid):
        return unread("only part of its id is on file")
    doc = item_doc(entity, pid)
    if not doc:
        return unread(f"the catalog has no such {entity}")
    arts = doc.get("artists")
    ids = [a.get("id") for a in arts if isinstance(a, dict)] if isinstance(arts, list) else None
    if ids is None or len(ids) != len(arts) or not all(isinstance(i, str) and UUID_RE.fullmatch(i) for i in ids):
        return Page(pid, entity, half_hidden=half_hidden, item_read=True, facts_unknown="artists")
    if not _is_number(doc.get("popularity")):
        return Page(pid, entity, half_hidden=half_hidden, item_read=True, facts_unknown="popularity")
    ids = list(dict.fromkeys(ids))
    if len(ids) > ITEM_MAX_ARTISTS:
        return unread(f"it has {len(ids)} artists")
    claims = processed_claims(ids) if ids else {}
    artists = tuple(page_facts([{"entity": "profile", "id": i} for i in ids], set(), claims))
    return Page(pid, entity, name=str(doc.get("title") or ""), popularity=float(doc.get("popularity")),
                half_hidden=half_hidden, item_read=True, artists=artists)


def page_facts(pages: list[dict], hidden: set[str], claims: dict[str, set[int]],
               half: dict[str, str] | None = None, items: bool = False) -> list[Page]:
    """`items=True` reads a track / album for the item gate. Off by default: a caller that does not ask for it gets
    the unread item every non-profile page was before (-> JAN_REVIEW), and performs no read for it."""
    half = half or {}
    out = []
    for p in pages:
        pid, ent = p["id"], p.get("entity") or "profile"
        if ent != "profile" or pid in hidden:
            if items and ent in ITEM_ENTITIES and pid not in hidden and not half.get(pid):
                out.append(item_page(ent, pid))
                continue
            out.append(Page(pid, ent, hidden=pid in hidden, half_hidden=half.get(pid, "")))
            continue
        if not UUID_RE.fullmatch(pid):
            out.append(Page(pid, ent, found=False, half_hidden=half.get(pid, "")))   # an 8-char prefix
            continue
        doc = profile_doc(pid)
        if not doc:
            # core answers 404 on a failed catalog read too: only a public 404 as well makes it "gone"
            gone = public_status("profile", pid) == 404
            out.append(Page(pid, ent, found=gone, gone=gone, half_hidden=half.get(pid, "")))
            continue
        links = doc.get("links") if isinstance(doc.get("links"), dict) else {}
        # isClaimed / popularity / creditCount are SAFETY fields: they decide whether path C may pass and whether the
        # page is a big name that goes to Jan. A missing or wrong-typed field is NOT false/0 - coercing absence made
        # an unclaimed big-name page auto-hide on facts the catalog never stated (QA on a3e68886a). Measured before
        # shipping the stricter rule: 32 of 32 live admin answers that were not 404 carry all three, correctly typed,
        # so this changes no current verdict and only refuses the answers that never established them.
        bad = [name for name, ok in (("isClaimed", isinstance(doc.get("isClaimed"), bool)),
                                     ("popularity", _is_number(doc.get("popularity"))),
                                     ("creditCount", _is_number(doc.get("creditCount")))) if not ok]
        if bad:
            out.append(Page(pid, ent, True, str(doc.get("name") or ""), facts_unknown=",".join(bad),
                            hidden=pid in hidden, half_hidden=half.get(pid, "")))
            continue
        # Only `processed_claims`' own answer carries `.links`; anything else has none, so a plain dict has no
        # claim with evidence.
        identity = profile_identity(doc)
        checked = frozenset(uid for uid, tokens in getattr(claims, "links", {}).get(pid, {}).items()
                            if any(link_matches_profile(token, identity) for token in tokens))
        out.append(Page(pid, ent, True, str(doc.get("name") or ""), doc.get("isClaimed") is True,
                        frozenset(claims.get(pid, set())), float(doc.get("popularity")),
                        int(doc.get("creditCount")), str(links.get("website") or ""), pid in hidden,
                        half_hidden=half.get(pid, ""), checked_claim_user_ids=checked))
    return out


# ---- the two hide lists (both must hold an id for it to count as hidden)

def gh_raw(repo: str, path: str, ref: str = "main") -> str:
    p = subprocess.run(["gh", "api", "-H", "Accept: application/vnd.github.raw",
                        f"repos/{repo}/contents/{path}?ref={ref}"], capture_output=True, text=True, timeout=120)
    if p.returncode:
        raise Unknown(f"gh read {repo}:{path}: {p.stderr.strip()[-200:]}")
    return p.stdout


def hidden_ids_from_yaml(text: str) -> set[str]:
    m = re.search(r"name: HIDDEN_ENTITY_IDS\s*\n\s*value:\s*\"([^\"]*)\"", text)
    if not m:
        raise Unknown("HIDDEN_ENTITY_IDS not found")
    return {x.strip().lower() for x in m.group(1).split(",") if x.strip()}


def legal_hidden_from_py(text: str) -> set[str]:
    return {m.lower() for m in re.findall(r'^\s*"(' + UUID_RE.pattern + r')":\s*\(', text, re.M)}


def hidden_lists() -> tuple[set[str], set[str]]:
    """(H-DevOps prod HIDDEN_ENTITY_IDS on main, PDP LEGAL_HIDDEN_ENTITY_IDS on main)."""
    return hidden_ids_from_yaml(gh_raw(HDEVOPS_REPO, HDEVOPS_FILES[0])), legal_hidden_from_py(gh_raw(PDP_REPO, PDP_LIST))


# ---- Intercom

def intercom(method: str, path: str, body: dict | None = None) -> dict:
    tok = os.environ.get("MUSOAI_INTERCOM_TOKEN", "")
    if not tok:
        raise Unknown("no Intercom token (MUSOAI_INTERCOM_TOKEN)")
    data = json.dumps(body).encode() if body is not None else None
    for attempt in range(5):
        req = urllib.request.Request(INTERCOM + path, data=data, method=method, headers={
            "Authorization": f"Bearer {tok}", "Accept": "application/json", "Content-Type": "application/json",
            "Intercom-Version": "2.11"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except urllib.error.HTTPError as exc:
            if exc.code in (429, 500, 502, 503, 504) and attempt < 4:
                time.sleep(3 * (attempt + 1))
                continue
            raise Unknown(f"Intercom {method} {path}: HTTP {exc.code}") from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            if attempt < 4:
                time.sleep(3 * (attempt + 1))
                continue
            raise Unknown(f"Intercom {method} {path}: {exc}") from exc
    raise Unknown(f"Intercom {method} {path}: retries exhausted")


def _plain(s: str) -> str:
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", s or ""))).strip()


MAX_PARTS_IN_RESPONSE = 500      # Intercom 2.11 returns at most the 500 most recent conversation parts
MAX_PART_PAGES = 20              # a bound on the backwards walk, so a pathological thread cannot spin forever

_CONV_CACHE: dict[str, dict] = {}


def _oldest(parts: list[dict], conv_id: str) -> int:
    """The oldest `created_at` in `parts`, refusing a part that carries none.

    `min(int(p.get("created_at") or 0) for p in parts)` reads a MISSING timestamp as 0, and 0 is older than every
    conversation, so the walk's `before <= created_at` floor test is satisfied on its FIRST iteration and
    `_all_parts` declares a truncated history complete. That is the exact opposite of what this module promises: a
    part we cannot date is a part we cannot place in the walk, so it is a refusal, never a floor.

    Reachable in production: Intercom omits `created_at` on some part types, and the 500-part cap means the part
    holding the customer's request is precisely the one we are walking back to find. Dropping it silently would
    report "no request" for a conversation that has one.
    """
    if not parts:
        raise Unknown(f"Intercom conversation {conv_id}: the backwards walk got an empty page, so there is no floor "
                      f"to step to - older parts (and any request in them) cannot be seen or dated - reconcile by hand")
    undated = sum(1 for p in parts if not p.get("created_at"))
    if undated:
        raise Unknown(
            f"Intercom conversation {conv_id}: {undated} of {len(parts)} part(s) carry no `created_at`, so the "
            f"backwards walk has no floor to step to - older parts (and any request in them) cannot be seen or "
            f"dated - reconcile by hand")
    return min(int(p["created_at"]) for p in parts)


def _all_parts(conv_id: str, newest: list[dict], created_at: int) -> list[dict]:
    """Every part of a conversation the API truncated at its 500-part cap, oldest first.

    The cap returns the 500 MOST RECENT parts, so the request itself can sit in the part that was dropped - which is
    why this used to fail closed and ask for a human. The documented way back is the TIME WINDOW: `parts_created_before`
    (accepted on 2.11, the version we pin - verified against a live 763-part thread) returns the parts at or before an
    instant, so walking backwards from the oldest part we hold reaches the conversation's opening message.

    It still fails closed if it cannot get there: a partial history cannot prove the customer's request is absent, and
    dating a row from what survived would drop it silently. The bound is a page count, not a time budget, so a thread
    that keeps returning fresh parts without reaching its own `created_at` is a refusal, never a truncated read.
    """
    if not created_at:
        raise Unknown(f"Intercom conversation {conv_id}: came back at the API's {MAX_PARTS_IN_RESPONSE}-part retrieval "
                      f"cap and the conversation carries no `created_at`, so there is no floor to walk back to")
    seen = {p.get("id") for p in newest}
    out = list(newest)
    before = _oldest(newest, conv_id)
    complete = False
    for _ in range(MAX_PART_PAGES):
        if before <= created_at:
            complete = True
            break
        page = intercom("GET", f"/conversations/{conv_id}?display_as=plaintext&parts_created_before={before}")
        got = (page.get("conversation_parts") or {}).get("conversation_parts") or []
        # `parts_created_before` is INCLUSIVE, so the boundary part comes back again; dedupe by id rather than
        # trusting the window to be half-open.
        fresh = [p for p in got if p.get("id") not in seen]
        if not fresh:
            # A page that adds nothing older is the floor ONLY if the API had nothing more to give. A FULL page that
            # adds nothing is the opposite: `parts_created_before` is inclusive and returns the 500 most recent parts
            # at or before `before`, so a full page of parts we already hold means there are at least
            # MAX_PARTS_IN_RESPONSE parts at exactly that instant and anything older sits beyond the page. Treating
            # that as the floor would accept a partial history and silently drop a request in the part we cannot see
            # (QA finding on #1779: 500 recent parts sharing one timestamp, no usable `total_count`).
            if len(got) >= MAX_PARTS_IN_RESPONSE:
                raise Unknown(
                    f"Intercom conversation {conv_id}: came back at the API's {MAX_PARTS_IN_RESPONSE}-part retrieval "
                    f"cap and the backwards walk is stuck at {before} - a full page of parts we already hold, so "
                    f"older parts (and any request in them) cannot be seen or dated - reconcile by hand")
            # Not full, so the API had nothing older: the whole history is in hand. This is also the floor for a
            # conversation of exactly 500 parts, whose oldest part is naturally later than `created_at`.
            complete = True
            break
        for p in fresh:
            seen.add(p.get("id"))
        out.extend(fresh)
        before = _oldest(fresh, conv_id)
    if not complete:
        raise Unknown(f"Intercom conversation {conv_id}: came back at the API's {MAX_PARTS_IN_RESPONSE}-part retrieval "
                      f"cap and the backwards walk stopped at {before} after {MAX_PART_PAGES} page(s) without reaching "
                      f"the conversation's opening message ({created_at}), so older parts (and any request in them) "
                      f"cannot be seen or dated - reconcile by hand")
    return sorted(out, key=lambda p: (int(p.get("created_at") or 0), str(p.get("id") or "")))


def conversation(conv_id: str) -> dict:
    """Cached per run (intake and decide read the same conversation)."""
    if conv_id not in _CONV_CACHE:
        _CONV_CACHE[conv_id] = _conversation(conv_id)
    return _CONV_CACHE[conv_id]


def _conversation(conv_id: str) -> dict:
    """The facts the identity rules may use, plus the CUSTOMER's own words (for class + page ids only).

    Two shapes that would otherwise turn OUR words into the customer's request, both failed closed:
      - an admin-initiated conversation (`source.author.type` = admin/teammate/bot): its source body is OUR message,
        so it never enters `parts`/`customer_text` and the admin's name/email never become the requester's. Only a
        customer-authored source is a customer statement (Intercom allows admins to open a thread, and an outbound
        "we will delete your profile <link>" would otherwise register as an erasure request and could reach a hide
        batch with nobody having asked);
      - a conversation with more parts than the API returns (the 2.11 retrieval cap, 500): a partial history cannot
        prove the customer's request is absent, so the read fails closed instead of being dated from what survived.
        `_all_parts` walks the rest back by time window, so the cap is no longer a dead end - only a walk that cannot
        reach the conversation's opening message is.
    """
    cv = intercom("GET", f"/conversations/{conv_id}?display_as=plaintext")
    src = cv.get("source") or {}
    author = src.get("author") or {}
    contacts = ((cv.get("contacts") or {}).get("contacts") or [])
    ct = intercom("GET", f"/contacts/{contacts[0]['id']}") if contacts else {}
    parts_obj = cv.get("conversation_parts") or {}
    raw_parts = parts_obj.get("conversation_parts") or []
    # The documented cap is 500 parts, and `total_count` counts the parts IN THE RESPONSE, so it cannot reveal that a
    # thread was truncated: a 600-part conversation comes back as exactly 500 parts with total_count=500. The only
    # detectable signal is the response sitting AT the cap, which therefore fails closed - an older part may hold the
    # erasure request itself, and dating the row from the surviving parts (then advancing the search cursor) would
    # drop it silently.
    if len(raw_parts) >= MAX_PARTS_IN_RESPONSE:
        raw_parts = _all_parts(conv_id, raw_parts, int(cv.get("created_at") or 0))
    # Belt, not the gate: `total_count` counts the parts IN THE RESPONSE, so it can never exceed what came back and
    # this can only fire if Intercom ever starts reporting a real total. Completeness is proven by `_all_parts`
    # reaching the conversation's opening message, never by this number.
    total = parts_obj.get("total_count")
    if isinstance(total, int) and total > len(raw_parts):
        raise Unknown(f"Intercom conversation {conv_id}: {len(raw_parts)} of {total} parts came back, so the history "
                      f"is incomplete - reconcile by hand")
    customer_author = str(author.get("type") or "").strip() in ("user", "lead", "contact")
    parts = [{"at": int(cv.get("created_at") or 0), "text": _plain(src.get("body") or "")}] if customer_author else []
    for p in raw_parts:
        if (p.get("author") or {}).get("type") in ("user", "lead", "contact") and p.get("body"):
            parts.append({"at": int(p.get("created_at") or cv.get("created_at") or 0), "text": _plain(p["body"])})
    return {
        "conversation_id": str(conv_id), "created_at": int(cv.get("created_at") or 0),
        "parts": [x for x in parts if x["text"]],
        "source_type": src.get("type") or "",
        # The SUBJECT drives `classify()`, so it is customer-authored text or nothing: an admin-opened thread titled
        # "Delete my profile" would otherwise classify a thread the customer only replied to with a URL.
        "subject": _plain(src.get("subject") or "") if customer_author else "",
        "author_name": (author.get("name") or "") if customer_author else "",
        "author_email": (author.get("email") or "").strip() if customer_author else "",
        "source_author_type": str(author.get("type") or ""),
        "contact_id": ct.get("id") or "", "external_id": str(ct.get("external_id") or ""),
        "contact_email": (ct.get("email") or "").strip(), "contact_name": ct.get("name") or "",
        "contact_role": ct.get("role") or "",
        "customer_text": "\n".join(x["text"] for x in parts if x["text"]),
        "state": cv.get("state") or "",
    }


def _search_page(field: str, since_epoch: int, cursor: str | None) -> tuple[list[str], str | None]:
    """One validated page of the Intercom conversation search: ([ids], next cursor or None).

    A 200 with no `conversations` list is NOT an empty final page: treating it as one ends the walk with a success,
    the caller advances its cursor, and every request in that window is silently lost. The response shape is part of
    the read, so a malformed page raises `Unknown` exactly like a 5xx does."""
    body = {"query": {"field": field, "operator": ">", "value": int(since_epoch)},
            "pagination": {"per_page": 150, **({"starting_after": cursor} if cursor else {})}}
    r = intercom("POST", "/conversations/search", body)
    if not isinstance(r, dict):
        raise Unknown(f"Intercom search ({field}): response is not an object")
    convs = r.get("conversations")
    if not isinstance(convs, list):
        raise Unknown(f"Intercom search ({field}): response has no conversations list "
                      f"(keys: {sorted(r) if isinstance(r, dict) else type(r).__name__})")
    ids = []
    for c in convs:
        if not isinstance(c, dict) or not str(c.get("id") or "").strip():
            raise Unknown(f"Intercom search ({field}): a conversation has no id")
        ids.append(str(c["id"]))
    # The pagination object is part of the read: without it nothing proves this is the LAST page, and guessing
    # "no next cursor means done" is exactly how a truncated response ends the walk with a success.
    pages = r.get("pages")
    if not isinstance(pages, dict):
        raise Unknown(f"Intercom search ({field}): response has no pages object, so the last page cannot be proven")
    nxt = pages.get("next")
    if nxt is not None and not isinstance(nxt, dict):
        raise Unknown(f"Intercom search ({field}): malformed pages.next")
    nxt_cursor = str((nxt or {}).get("starting_after") or "").strip()
    if nxt_cursor:
        if nxt_cursor == cursor:
            raise Unknown(f"Intercom search ({field}): pagination cursor did not advance")
        return ids, nxt_cursor
    page, total = pages.get("page"), pages.get("total_pages")
    if not isinstance(page, int) or not isinstance(total, int) or page < total:
        raise Unknown(f"Intercom search ({field}): no next cursor and page {page!r} of {total!r} does not prove "
                      f"the last page")
    return ids, None


def search_conversations(since_epoch: int) -> list[str]:
    """Conversation ids CREATED since `since_epoch` OR UPDATED since it (every page; raises on a failed page).

    Both fields matter: a customer who replies to an old thread today ("please delete my data") changes an
    existing conversation, and a created_at-only search would never return it — the request would never reach
    the register or the due-date watchdog unless Caroline happened to file a ticket. Updated_at also catches
    newly-filed tickets' conversations. The union is deduplicated; a failure on either field fails the read.
    """
    out: dict[str, None] = {}
    for field in ("created_at", "updated_at"):
        cursor = None
        while True:
            ids, cursor = _search_page(field, since_epoch, cursor)
            for cid in ids:
                out.setdefault(cid, None)
            if not cursor:
                break
    return list(out)


# ---- ClickUp

def clickup_tasks(action_type: str) -> list[dict]:
    from lib import clickup_client
    key = os.environ.get("CLICKUP_API_KEY") or os.environ.get("MUSOAI_CLICKUP_API_KEY") or ""
    if not key:
        raise Unknown("no ClickUp key")
    try:
        return clickup_client.shared(key).list_tasks(
            CLICKUP_LIST, [("tags[]", f"action:{action_type}"), ("include_closed", "true"), ("subtasks", "true")], 60)
    except Exception as exc:  # noqa: BLE001 -- any failed page is an incomplete scan
        raise Unknown(f"ClickUp {action_type}: {exc}") from exc
