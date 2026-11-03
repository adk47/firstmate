"""Live, READ-ONLY facts for every open profile-merge ticket, in the shape rules.decide reads.

Sources (every one a read; nothing here can write):
  - ClickUp User Requests list (default 901000600160): open `action:profile-merge` tickets, GET only.
    The keep and the duplicates come from the ticket's own `merge_intake` (or the ACTION-REQUEST
    details' main/duplicate fields), never from an id match against other tickets.
  - Core replica (Trino `postgresql_core.public.*`, scripts/trino-query.sh): claiming (with the
    screening flags), users (login profile, account email), user_identity_resolution (confirmed
    presented primary, tier confirmed|high, the rule core's merge route applies), profile_merges
    (the ledger, followed along verified chains), roster_seats x subscriptions (paid seats, core's
    PAYING_SUB predicate).
  - Catalog through core's admin API (credit_review.admin.AdminClient, GET-only by construction):
    `/admin/profile?includeDeleted=true&ids=...` and `/admin/profile/search?keyword=` for the
    same-name census.
  - Intercom: the requester's own conversations, found by the ACCOUNT's email (never the ticket's
    free text), and the user-authored parts of each (the profile ids the requester named). Only the
    two search endpoints (POST is how Intercom searches) and conversation GETs are reachable.
  - policies/fraud-watchlist.json (credit_review.watchlist).

A read that fails leaves its section None for the affected tickets: the rule then answers UNKNOWN.
"""
from __future__ import annotations

import json
import os
import re
import time
import urllib.parse
import urllib.request
from collections import defaultdict
from typing import Any, Callable, Iterable

from . import rules

UUID_ANY = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I)
CLICKUP_API = "https://api.clickup.com/api/v2"
INTERCOM_API = "https://api.intercom.io"
DEFAULT_LIST = "901000600160"
PAYING_SUB = ("(s.status IN ('active', 'trial') OR ((s.plan = 'vip' OR s.plan = 'custom' OR s.plan LIKE '%business%' "
              "OR s.plan LIKE '%pro%') AND s.status IS NULL))")  # core claimPaidFlags.PAYING_SUB, kept identical
PRIMARY_TIERS = ("confirmed", "high")  # core resolvePresentedIdentity.ALLOWED_TIERS
INTERCOM_READS = {("POST", "/contacts/search"), ("POST", "/conversations/search")}

Query = Callable[[str], list[list[str]]]


class ReadOnlyViolation(RuntimeError):
    pass


# ── transports (GET / read-only search only) ──────────────────────────────────────────────────

def _http(method: str, url: str, headers: dict, body: Any = None, timeout: int = 30) -> Any:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={**headers, "Accept": "application/json",
                                                                         **({"Content-Type": "application/json"} if data else {})})
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310 - fixed API hosts
        return json.load(r)


class ClickUp:
    def __init__(self, key: str, http: Callable = _http, pace: float = 0.4):
        self.key, self.http, self.pace = key, http, pace

    def get(self, path: str) -> Any:
        out = self.http("GET", CLICKUP_API + path, {"Authorization": self.key})
        time.sleep(self.pace)
        return out


class Intercom:
    def __init__(self, token: str, http: Callable = _http, pace: float = 0.2):
        self.h = {"Authorization": f"Bearer {token}", "Intercom-Version": "2.11"}
        self.http, self.pace = http, pace

    def call(self, method: str, path: str, body: Any = None) -> Any:
        bare = path.split("?", 1)[0]
        if method != "GET" and (method, bare) not in INTERCOM_READS:
            raise ReadOnlyViolation(f"intercom {method} {bare} is not a read")
        if method == "GET" and not bare.startswith("/conversations/"):
            raise ReadOnlyViolation(f"intercom GET {bare} is not a conversation read")
        out = self.http(method, INTERCOM_API + path, self.h, body)
        time.sleep(self.pace)
        return out


# ── tickets ───────────────────────────────────────────────────────────────────────────────────

def parse_ticket(task: dict) -> dict:
    """keep / duplicates / conversation / customer email from one ClickUp task (m1's parser)."""
    d = task.get("description") or task.get("text_content") or ""
    ar: dict = {}
    m = re.search(r"---ACTION-REQUEST---\s*(\{.*?\})\s*---END-ACTION-REQUEST---", d, re.S)
    if m:
        for text in (m.group(1), re.sub(r"\\([^\"\\/bfnrtu])", r"\1", m.group(1))):
            try:
                ar = json.loads(text)
                break
            except ValueError:
                continue
    det = ar.get("details") or {} if isinstance(ar, dict) else {}
    mi = det.get("merge_intake") or {}
    keep_src = (mi.get("keep") or det.get("main_profile_url") or det.get("survivor_profile_url")
                or det.get("main_profile_id") or det.get("survivor_profile_id") or ar.get("customer_profile_id") or "")
    k = UUID_ANY.search(str(keep_src))
    keep = k.group(0).lower() if k else None
    dups = sorted({u.lower() for u in UUID_ANY.findall(json.dumps([mi.get("others"), det.get("duplicate_profile_urls"),
                                                                   det.get("duplicate_profile_ids"),
                                                                   det.get("duplicate_profile_id")]))} - {keep})
    conv = ar.get("intercom_conversation_id") or ar.get("conversation_id") if isinstance(ar, dict) else None
    if not conv:
        c = re.search(r"conversations?/(\d{6,})|Conversation:\s*(\d{6,})", d)
        conv = next((g for g in c.groups() if g), None) if c else None
    em = re.search(r'customer_email\\?"?\s*:\s*\\?"([^"\\]+@[^"\\]+)', d) or re.search(r"Customer:\s*(\S+@\S+)", d)
    return {"ticket": task["id"], "status": (task.get("status") or {}).get("status"),
            "status_type": (task.get("status") or {}).get("type"),
            "tags": [x.get("name") for x in task.get("tags") or []], "created_ms": int(task.get("date_created") or 0),
            "priority": (task.get("priority") or {}).get("priority") if isinstance(task.get("priority"), dict) else None,
            "keep": keep, "dups": dups, "conv": str(conv) if conv else None,
            "ticket_email": em.group(1).strip().lower() if em else None}


def open_merge_tickets(cu: ClickUp, list_id: str = DEFAULT_LIST) -> list[dict]:
    tasks, seen = [], set()
    for page in range(200):
        q = urllib.parse.urlencode([("archived", "false"), ("include_closed", "false"), ("subtasks", "true"),
                                    ("order_by", "created"), ("page", str(page)), ("tags[]", "action:profile-merge")])
        body = cu.get(f"/list/{list_id}/task?{q}")
        if not isinstance(body, dict) or "tasks" not in body:
            raise RuntimeError(f"clickup page {page}: malformed")
        for t in body["tasks"]:
            if t.get("id") not in seen:
                seen.add(t.get("id"))
                tasks.append(t)
        if not body["tasks"] or body.get("last_page"):
            break
    # ClickUp's include_closed=false still returns custom "done"-type statuses (complete, resolved):
    # an OPEN request is one whose status type is neither closed nor done (m1's 235).
    return [parse_ticket(t) for t in tasks
            if str((t.get("status") or {}).get("type") or "").lower() not in ("closed", "done")]


# ── replica ───────────────────────────────────────────────────────────────────────────────────

def _q(ids: Iterable[str]) -> str:
    vals = sorted({i.lower() for i in ids if rules.UUID.match(i.lower())})
    return ",".join(f"'{v}'" for v in vals) or "''"


def _chunks(xs: list, n: int) -> Iterable[list]:
    for i in range(0, len(xs), n):
        yield xs[i:i + n]


def replica_facts(pids: list[str], query: Query) -> dict[str, Any]:
    out: dict[str, Any] = {"claims": defaultdict(list), "identity": [], "merges": [], "paid": {p: [] for p in pids}}
    for ch in _chunks(sorted(set(pids)), 300):
        ids = _q(ch)
        # The replica's claiming has no screening columns (screeningRiskFlags / screeningRecommendation
        # live only on core's primary), so `flagged` is None: recorded as not read, and core's own
        # merge guards re-check them at execution.
        for pid, status, uid, team in query(
                "SELECT lower(profileid), status, CAST(userid AS varchar), CAST(teamid AS varchar) "
                f"FROM postgresql_core.public.claiming WHERE deletedat IS NULL AND lower(profileid) IN ({ids})"):
            out["claims"][pid].append({"status": status, "user_id": uid or None, "team_id": team or None, "flagged": None})
        for uid, pid in query("SELECT CAST(id AS varchar), lower(CAST(neptuneprofessionalid AS varchar)) "
                              f"FROM postgresql_core.public.users WHERE lower(CAST(neptuneprofessionalid AS varchar)) IN ({ids})"):
            out["identity"].append({"profile_id": pid, "user_id": uid, "kind": "login"})
        tiers = ",".join(f"'{t}'" for t in PRIMARY_TIERS)
        for uid, pid in query("SELECT CAST(user_id AS varchar), lower(CAST(candidate_profile_id AS varchar)) "
                              "FROM postgresql_core.public.user_identity_resolution WHERE is_primary AND is_confirmed "
                              f"AND NOT is_rejected AND confidence_tier IN ({tiers}) "
                              f"AND lower(CAST(candidate_profile_id AS varchar)) IN ({ids})"):
            out["identity"].append({"profile_id": pid, "user_id": uid, "kind": "primary"})
        for pid, team in query("SELECT DISTINCT lower(CAST(rs.seatid AS varchar)), CAST(rs.teamid AS varchar) "
                               "FROM postgresql_core.public.roster_seats rs JOIN postgresql_core.public.subscriptions s "
                               f"ON s.teamid = rs.teamid WHERE rs.status IN ('active', 'paused') AND {PAYING_SUB} "
                               f"AND lower(CAST(rs.seatid AS varchar)) IN ({ids})"):
            out["paid"].setdefault(pid, []).append(team)
    # the ledger, followed along every row it names (a duplicate may forward through a third profile)
    frontier, seen = set(pids), set()
    while frontier:
        batch = sorted(frontier - seen)[:300]
        if not batch:
            break
        seen |= set(batch)
        ids = _q(batch)
        rows = query("SELECT lower(CAST(loser_profile_id AS varchar)), lower(CAST(survivor_profile_id AS varchar)), status, "
                     "CAST(merge_request_id AS varchar) FROM postgresql_core.public.profile_merges "
                     f"WHERE lower(CAST(loser_profile_id AS varchar)) IN ({ids}) OR lower(CAST(survivor_profile_id AS varchar)) IN ({ids})")
        for loser, survivor, status, mrid in rows:
            row = {"loser": loser, "survivor": survivor, "status": status, "merge_request_id": mrid}
            if row not in out["merges"]:
                out["merges"].append(row)
            if status == "verified":
                frontier |= {loser, survivor}
        frontier -= seen
    return out


def account_emails(user_ids: Iterable[str], query: Query) -> dict[str, str]:
    ids = sorted({str(u) for u in user_ids if str(u).isdigit()})
    out: dict[str, str] = {}
    for ch in _chunks(ids, 400):
        for uid, email in query(f"SELECT CAST(id AS varchar), lower(email) FROM postgresql_core.public.users WHERE id IN ({','.join(ch)})"):
            out[uid] = (email or "").strip()
    return out


# ── catalog ───────────────────────────────────────────────────────────────────────────────────

def _profile_fact(p: dict) -> dict:
    raws = p.get("rawProfiles") or []
    spotify = ({str(p["spotifyId"])} if p.get("spotifyId") else set()) | {
        str(r.get("id")) for r in raws if (r.get("source") or "").lower() == "spotify" and r.get("id")}
    tidal = {str(x) for x in (p.get("tidalIds") or []) if x} | {
        str(r.get("id")) for r in raws if (r.get("source") or "").lower() == "tidal" and r.get("id")}
    names = [n for n in [p.get("name"), p.get("legalName"), *(p.get("knownAsNames") or []), *[r.get("name") for r in raws]]
             if isinstance(n, str) and n.strip()]
    merged = p.get("merged") or {}
    return {"found": True, "type": p.get("type"), "sub_type": p.get("subType"),
            "credits": p.get("creditCount") if isinstance(p.get("creditCount"), int) else None,
            "popularity": p.get("popularity") if isinstance(p.get("popularity"), (int, float)) else None,
            "spotify": sorted(spotify), "tidal": sorted(tidal), "names": names,
            "merged_to": (merged.get("toId") or merged.get("id")) if isinstance(merged, dict) else None,
            "deleted": bool(p.get("deleted"))}


def catalog_facts(pids: list[str], admin: Any) -> dict[str, dict]:
    """{pid: fact}; a chunk whose read fails leaves its ids `found: None` (unknown, not missing)."""
    out: dict[str, dict] = {}

    def read(ch: list[str]) -> list | None:
        qs = "&".join(["includeDeleted=true", f"limit={len(ch)}"] + [f"ids={i}" for i in ch])
        try:
            body = admin.get(f"/admin/profile?{qs}")
        except Exception:  # noqa: BLE001 - an unreadable chunk is unknown, never "not found"
            return None
        items = body.get("items") if isinstance(body, dict) else None
        return items if isinstance(items, list) else None

    for ch in _chunks(sorted(set(pids)), 50):
        parts = [(ch, read(ch))]
        if parts[0][1] is None:  # one retry, in chunks of 10, so one bad read cannot blind 50 tickets
            parts = [(sub, read(sub)) for sub in _chunks(ch, 10)]
        for sub, items in parts:
            if items is None:
                out.update({i: {"found": None} for i in sub})
                continue
            got = {str(p.get("id")).lower(): p for p in items if isinstance(p, dict) and p.get("id")}
            for i in sub:
                out[i] = _profile_fact(got[i]) if i in got else {"found": False}
    return out


CENSUS_PAGE = 50
CENSUS_MAX_PAGES = 20  # 1,000 results: past this the census answers UNKNOWN, never "nobody else"


def same_name_others(name: str, sides: set[str], admin: Any) -> bool | None:
    """Is there ANOTHER profile with this exact folded name that is claimed or holds credits?

    The search is ranked by its own score, so a conflicting exact-name profile can sit anywhere in
    the result set: one page is not the census. Pages are walked to exhaustion (a short page means
    the end). A page that cannot be read, or a result set still full at CENSUS_MAX_PAGES, answers
    None = UNKNOWN - a truncated census must never say "nobody else", because that would let
    `eligible` skip the common-name guard.
    """
    f = rules.fold_name(name)
    if not f:
        return None
    for page in range(1, CENSUS_MAX_PAGES + 1):
        try:
            body = admin.get("/admin/profile/search?" + urllib.parse.urlencode(
                {"keyword": name, "limit": CENSUS_PAGE, "page": page}))
        except Exception:  # noqa: BLE001 - an unreadable page is unknown, never "no match"
            return None
        items = body.get("items") if isinstance(body, dict) else body if isinstance(body, list) else None
        if not isinstance(items, list):
            return None
        for p in items:
            if not isinstance(p, dict) or str(p.get("id", "")).lower() in sides or rules.fold_name(p.get("name")) != f:
                continue
            if p.get("isClaimed") or (isinstance(p.get("creditCount"), int) and p["creditCount"] > 0):
                return True
        if len(items) < CENSUS_PAGE:
            return False
    return None


# ── requester threads ─────────────────────────────────────────────────────────────────────────

def requester_threads(email: str, ic: Intercom) -> list[dict]:
    """Every conversation of the Intercom USER contact with this exact email, with the profile ids
    the requester wrote in their own parts. bound = exactly one user-role contact has the email
    (a `lead` with the same email is an anonymous visitor: never counted, never bound) and the
    conversation has exactly that one contact. Intercom Identity Verification is off, so this is an
    email binding; the row says so."""
    found = ic.call("POST", "/contacts/search", {"query": {"field": "email", "operator": "=", "value": email}}).get("data") or []
    contacts = [c for c in found if str(c.get("role") or "user").lower() == "user"
                and str(c.get("email") or email).strip().lower() == email.strip().lower()]
    if not contacts:
        return []
    out = []
    for c in contacts[:3]:
        q = {"query": {"field": "contact_ids", "operator": "=", "value": c["id"]}, "pagination": {"per_page": 50}}
        for cv in ic.call("POST", "/conversations/search", q).get("conversations") or []:
            full = ic.call("GET", f"/conversations/{cv['id']}?display_as=plaintext")
            parts = [full.get("source") or {}] + ((full.get("conversation_parts") or {}).get("conversation_parts") or [])
            text = " ".join((p.get("body") or "") for p in parts
                            if (p.get("author") or {}).get("type") in ("user", "lead", "contact")
                            and str((p.get("author") or {}).get("id") or c["id"]) == str(c["id"]))
            members = ((full.get("contacts") or {}).get("contacts") or [])
            out.append({"conv": str(cv["id"]), "bound": len(contacts) == 1 and len(members) == 1
                        and str(members[0].get("id")) == str(c["id"]),
                        "named_ids": sorted({u.lower() for u in UUID_ANY.findall(text)}), "state": full.get("state"),
                        "binding": "account email, one Intercom user contact (identity verification off)"})
    return out


def ledger_rows(rows: list[dict], sides: list[str]) -> list[dict]:
    """The ledger rows that touch this ticket: every row naming one of its profiles, plus the
    verified chain onward from each (a duplicate may forward through a third profile)."""
    verified = {}
    for m in rows:
        if m["status"] == "verified":
            verified.setdefault(m["loser"], m)
    out = [m for m in rows if m["loser"] in sides or m["survivor"] in sides]
    for pid in sides:
        seen = 0
        while pid in verified and seen < 20:
            if verified[pid] not in out:
                out.append(verified[pid])
            pid, seen = verified[pid]["survivor"], seen + 1
    return out


# ── assemble ──────────────────────────────────────────────────────────────────────────────────

def collect(*, cu: ClickUp, admin: Any, query: Query, ic: Intercom | None, watchlist: Any,
            holds: dict | None = None, list_id: str = DEFAULT_LIST, limit: int | None = None) -> list[dict]:
    """`watchlist` = credit_review.watchlist.load(); `holds` = credit_review.fraud_lens.load_holds()
    ({user id: reason}); a requester in either is held, never merged automatically."""
    holds = holds or {}
    tickets = open_merge_tickets(cu, list_id)
    if limit:
        tickets = tickets[:limit]
    pids = sorted({p for t in tickets for p in [t["keep"], *t["dups"]] if p})
    started = time.time()
    try:
        cat = catalog_facts(pids, admin)
    except Exception:  # noqa: BLE001
        cat = None
    try:
        rep = replica_facts(pids, query)
    except Exception:  # noqa: BLE001
        rep = None
    users = {c["user_id"] for cs in (rep or {}).get("claims", {}).values() for c in cs
             if c.get("status") == "processed" and c.get("user_id")}
    try:
        emails = account_emails(users, query) if rep else {}
    except Exception:  # noqa: BLE001
        emails = {}
    thread_cache: dict[str, list | None] = {}
    out = []
    for t in tickets:
        sides = [p for p in [t["keep"], *t["dups"]] if p]
        row = {k: t[k] for k in ("ticket", "status", "tags", "created_ms", "priority", "conv", "keep", "dups")}
        row["profiles"] = {p: cat.get(p, {"found": None}) for p in sides} if cat is not None else None
        if rep is None:
            row.update(claims=None, identity=None, merges=None, paid=None)
        else:
            row["claims"] = {p: rep["claims"].get(p, []) for p in sides}
            row["identity"] = [r for r in rep["identity"] if r["profile_id"] in sides]
            row["merges"] = ledger_rows(rep["merges"], sides)
            row["paid"] = {p: rep["paid"].get(p, []) for p in sides}
        # a team-held claim has no user id: the claimant ACCOUNT is the one user id the claims name
        claimants = {c["user_id"] for p in sides for c in (row["claims"] or {}).get(p, [])
                     if c.get("status") == "processed" and c.get("user_id")}
        row["watchlist"] = {"profile_ids": [p for p in sides if p in watchlist.profile_ids],
                            "requester_hit": any(str(u).isdigit() and (int(u) in watchlist.user_ids or int(u) in holds)
                                                 for u in claimants)
                            or any(watchlist.email_hit(emails.get(u, "")) for u in claimants)}
        # owner confirmation: threads of the single claimant ACCOUNT's own email
        threads: list | None = None
        if ic is not None and len(claimants) == 1:
            email = emails.get(next(iter(claimants)), "")
            if email:
                if email not in thread_cache:
                    try:
                        thread_cache[email] = requester_threads(email, ic)
                    except Exception:  # noqa: BLE001
                        thread_cache[email] = None
                threads = thread_cache[email]
        row["threads"] = threads
        pairs = {}
        for loser in t["dups"]:
            kp = (row["profiles"] or {}).get(t["keep"] or "", {}) if row["profiles"] else {}
            lp = (row["profiles"] or {}).get(loser, {}) if row["profiles"] else {}
            rel = rules.best_name_relation(kp.get("names") or [], lp.get("names") or [])
            census = None
            if kp.get("found") and lp.get("found"):
                vals = [same_name_others(n, set(sides), admin) for n in {kp["names"][0] if kp.get("names") else "",
                                                                          lp["names"][0] if lp.get("names") else ""} if n]
                census = None if (not vals or any(v is None for v in vals)) else any(vals)
            pairs[loser] = {"name_relation": rel, "same_name_others": census}
        row["pairs"] = pairs
        row["read"] = {"started": started, "finished": time.time(), "fresh": True}
        out.append(row)
    return out


def env_clients() -> tuple[ClickUp, Intercom | None]:
    key = os.environ.get("CLICKUP_API_KEY") or os.environ.get("MUSOAI_CLICKUP_API_KEY")
    if not key:
        raise SystemExit("CLICKUP_API_KEY (or MUSOAI_CLICKUP_API_KEY) is required")
    token = os.environ.get("MUSOAI_INTERCOM_TOKEN")
    return ClickUp(key), (Intercom(token) if token else None)
