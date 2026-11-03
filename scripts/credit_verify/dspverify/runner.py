"""The verifier's runs: submit fresh captures for pending requests, then read them and log verdicts.

  submit  pending (unverified) credit requests, paid first then oldest, not already under an open
          capture or verified in the last day -> grouped per user (<= 30 tracks a group) -> one
          fresh Spotify + Tidal capture request per group (pod_driver submit) -> dsp_captures.
  verify  every open capture -> pod_driver read -> per credit request: packet (core request +
          catalog popularity + profile + label strings + account gate + watchlist / deny lists +
          duplicate check + the capture reading) -> rules.verify -> dsp_verdicts. A capture with a
          reading still WAITING stays open and is read again next run (mid-window and at close,
          d3 §2); it closes once every reading is final or the 90-minute window has passed.

Writes only its own store. Core is read with GETs only (credit_review.admin refuses anything
else); the account gate is the shared read-only check; nothing is sent to anybody.
"""

from __future__ import annotations

import json
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any, Callable

from credit_review import account_gate
from credit_review import admin as admin_api
from credit_review.evidence import EvidenceBuilder, parse_ts
from credit_review.roles import family_of

from . import rules
from .store import Store, utcnow

GROUP_TRACKS = 30                 # tracks per capture request (the deciders' grouping)
EXEC_BATCH = 10                   # capture requests per kubectl exec
CLOSE_AFTER = timedelta(minutes=100)   # past the 90-min window a WAITING reading is final (NO_FRESH_CAPTURE)
REVERIFY_AFTER = timedelta(days=1)

CaptureCall = Callable[[str, list[dict[str, Any]]], list[dict[str, Any]]]
GateFn = Callable[[Any], account_gate.GateResult]


@dataclass
class Deps:
    admin: admin_api.Admin
    capture: CaptureCall
    gate: GateFn
    deny_user_ids: frozenset[int] = frozenset()
    deny_profile_ids: frozenset[str] = frozenset()
    watch_user_ids: frozenset[int] | None = None       # policies/fraud-watchlist.json; None = not read
    watch_profile_ids: frozenset[str] | None = None
    paying: frozenset[int] | None = None
    select: "Select | None" = None
    # (user_id, org profile_id) -> True (a processed, live organization claim) | False | None (unknown).
    org_claim: Callable[[int | None, str], bool | None] = lambda uid, pid: None
    now: Callable[[], datetime] = lambda: datetime.now(timezone.utc)
    log: Callable[[str], None] = lambda m: None


@dataclass
class Stats:
    run_id: str
    kind: str
    requests: int = 0
    groups: int = 0
    errors: list[str] = field(default_factory=list)
    verdicts: dict[str, int] = field(default_factory=dict)
    classes: dict[str, int] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {"run_id": self.run_id, "kind": self.kind, "requests": self.requests, "groups": self.groups,
                "verdicts": self.verdicts, "classes": self.classes, "errors": self.errors[:10]}


def new_run_id(kind: str) -> str:
    return f"dsp-{kind}-{utcnow()}-{uuid.uuid4().hex[:8]}"


# ── selection ──────────────────────────────────────────────────────────────────
OPEN_STATUSES = ("unverified", "user_verification_needed")
# A tray run may also check rows already APPROVED (Fable validator-wrong-16: were they anchored?).
# Shadow only: the verdict is evidence about the row, nothing is taken back.
TRAY_STATUSES = OPEN_STATUSES + ("approved",)

# (statuses, only request ids or None, max rows, paying user ids or None) -> [{"id", "profile_id",
# "track_id"}] PAYING users' requests first, then oldest first (the ordering is applied BEFORE the limit,
# so a paid request is never cut by a window full of free ones; QA @fba5057). Production:
# a read-only Trino SELECT (trino_open_requests). The admin list is never paged unscoped: the wrapper
# refuses limit > 200 without a profile/track filter (hydra #1270, the 10-19 deep-paging incident).
Select = Callable[..., list[dict[str, str]]]


def _scoped_reads(admin: admin_api.Admin, scopes: list[tuple[str, str]], statuses: tuple[str, ...],
                  want: set[str], pages: int) -> dict[str, dict[str, Any]]:
    """Admin list reads, each filtered by ONE track ("track", id) or ONE profile ("profile", id): the
    wrapper refuses unscoped reads above limit 200 and core 500s on several profilesIds. A track
    holds few requests, so a track read is preferred (a busy profile can hold thousands)."""
    rows: dict[str, dict[str, Any]] = {}
    for kind, sid in scopes:
        for status in statuses:
            for page in range(1, pages + 1):
                kw = {"track_id": sid} if kind == "track" else {"profile_ids": [sid]}
                items = admin_api.list_requests(admin, status=status, limit=200, page=page, **kw)
                rows.update({str(r.get("id")).lower(): r for r in items if str(r.get("id")).lower() in want})
                if len(items) < 200:
                    break
            else:
                raise admin_api.AdminError(f"{status} list for {kind} {sid} still full after {pages} pages")
    return rows


def pending_requests(admin: admin_api.Admin, select: "Select", statuses: tuple[str, ...],
                     only: set[str] | None, limit: int, skip: set[str] | None = None,
                     paying: frozenset[int] | None = None,
                     seen: set[str] | None = None) -> list[dict[str, Any]]:
    """Requests in `statuses`: ids from `select` (Trino), minus `skip`, at most `limit`; then the full
    rows through scoped admin reads (one track per read, or one profile when the track is unknown).
    The skip set is applied to the ids BEFORE the limit, and the selection window is widened by its
    size, so requests already captured/verified can never starve the newer ones (QA @b1c4798).

    [key=novelty-is-a-window-property] (QA @292b6ac, @9daaa07): the window ADVANCES a page at a time
    rather than growing from the same first row. Growing a LIMIT re-reads the same prefix, so a backlog
    of familiar rows longer than the last window still hides request N+1 forever (QA: 1,200 decided rows
    then a first-time one - windows of 300/600/1,200 all fill with familiar rows). OFFSET pagination
    makes progress monotonic: page 2 starts where page 1 stopped, so any backlog within
    MAX_SELECT_PAGES * window is reached. [key=novelty-accumulates-across-pages] (QA @5747140631):
    novelty ACCUMULATES across pages - stopping on a page that merely CONTAINS one new id spent the whole
    batch on 299 familiar rows while 300 new ids waited on the next page. The walk ends only when the
    batch is full of first-time work or the source runs out, and familiar ids fill just the slots no new
    request claimed (the floor). The read stays bounded by a constant (never an unbounded scan) and the
    expensive scoped admin read still happens ONCE, over the picked ids only."""
    skip = {str(x).lower() for x in (skip or set())}
    familiar = {str(x).lower() for x in (seen or set())}
    window = limit + len(skip)
    novel: list[dict[str, Any]] = []      # [key=novelty-accumulates-across-pages] (QA @5747140631): real new work
    floor: list[dict[str, Any]] = []      # familiar work, only to fill slots no new request claimed
    seen_novel: set[str] = set()
    seen_floor: set[str] = set()
    offset = 0
    for _ in range(MAX_SELECT_PAGES):
        raw = select(statuses, only, window, paying, offset=offset)
        for p in prioritize([p for p in raw if str(p["id"]).lower() not in skip], seen):
            pid = str(p["id"]).lower()
            if familiar and pid in familiar:
                if pid not in seen_floor:
                    seen_floor.add(pid)
                    floor.append(p)
            elif pid not in seen_novel:
                seen_novel.add(pid)
                novel.append(p)
        # stop only when the batch is FULL of new work or the source is exhausted: a page that merely
        # CONTAINS one new id is not a reason to stop, or 299 familiar rows + 1 new spend the batch and the
        # 300 new ids on the next page are never read
        if len(novel) >= limit or len(raw) < window:
            break
        offset += window
    picked = novel[:limit]
    if len(picked) < limit:                       # only THEN does familiar work fill what new work did not
        have = {str(p["id"]).lower() for p in picked}
        picked += [p for p in floor if str(p["id"]).lower() not in have][:limit - len(picked)]
    want = {str(p["id"]).lower() for p in picked}
    scopes = sorted({("track", str(p["track_id"])) if p.get("track_id") else ("profile", str(p["profile_id"]))
                     for p in picked if p.get("track_id") or p.get("profile_id")})
    return list(_scoped_reads(admin, scopes, statuses, want, 10).values())


MAX_SELECT_PAGES = 8


def prioritize(picked: list[dict[str, Any]], seen: set[str] | None) -> list[dict[str, Any]]:
    """[key=reverify-is-a-floor-not-an-order]: a request we have never decided goes first; an id we have ALREADY
    decided only fills the slots nobody new claimed, so the floor still re-verifies when it is all the work there
    is. Ordering inside the SAME window - it never widens the read and never adds a scan."""
    if not seen:
        return picked
    already = {str(x).lower() for x in seen}
    fresh = [p for p in picked if str(p["id"]).lower() not in already]
    return fresh + [p for p in picked if str(p["id"]).lower() in already] if fresh else picked


OPEN_SQL = ("SELECT cast(cr.id AS varchar), cast(cr.profileid AS varchar), cast(cr.trackid AS varchar)"
            " FROM postgresql_core.public.credit_requests cr"
            " WHERE cr.deletedat IS NULL AND cr.status IN ({statuses}){only}"
            " ORDER BY {paid}cr.createdat, cr.id LIMIT {limit} OFFSET {offset}")
MAX_PAYING_IDS_IN_SQL = 20000


def trino_open_requests(query: Callable[[str], str]) -> "Select":
    import csv
    import io
    import re

    def select(statuses: tuple[str, ...], only: set[str] | None, limit: int,
               paying: frozenset[int] | None = None, offset: int = 0) -> list[dict[str, str]]:
        st = ",".join(f"'{x}'" for x in statuses if re.fullmatch(r"[a-z_]+", x))
        clause = ""
        if only is not None:
            ids = sorted(x for x in only if re.fullmatch(r"[0-9a-f-]{36}", x))
            if not ids:
                return []
            clause = " AND cr.id IN (" + ",".join(f"uuid '{x}'" for x in ids) + ")"
        paid = ""
        ids_paying = sorted(int(u) for u in (paying or ()) if isinstance(u, int) and not isinstance(u, bool))
        if ids_paying:
            if len(ids_paying) > MAX_PAYING_IDS_IN_SQL:
                raise ValueError(f"{len(ids_paying)} paying ids exceed the selector's {MAX_PAYING_IDS_IN_SQL}")
            paid = "CASE WHEN cr.userid IN (" + ",".join(map(str, ids_paying)) + ") THEN 0 ELSE 1 END, "
        out = query(OPEN_SQL.format(statuses=st, only=clause, limit=int(limit), paid=paid,
                                    offset=int(offset)))
        rows = []
        for r in csv.reader(io.StringIO(out)):
            if len(r) >= 2 and re.fullmatch(r"[0-9a-f-]{36}", r[0] or ""):
                rows.append({"id": r[0], "profile_id": r[1], "track_id": r[2] if len(r) > 2 and r[2] else None})
        return rows
    return select


def order(rows: list[dict[str, Any]], paying: frozenset[int] | None) -> list[dict[str, Any]]:
    """Paid first, then oldest (ordering only; paying status never changes a verdict)."""
    def key(r: dict[str, Any]) -> tuple[int, str]:
        uid = r.get("userId")
        return (0 if paying is not None and uid in paying else 1, str(r.get("createdAt") or ""))
    return sorted(rows, key=key)


def names_of(req: dict[str, Any], doc: dict[str, Any] | None) -> list[str]:
    doc = doc or {}
    names = [str(doc.get("name") or (req.get("profile") or {}).get("name") or "")]
    names += [str(a) for a in (doc.get("knownAsNames") or []) if a]
    if doc.get("legalName"):
        names.append(str(doc["legalName"]))
    return [n for n in dict.fromkeys(names) if n]


def groups_for(rows: list[dict[str, Any]], builder: EvidenceBuilder) -> dict[str, dict[str, Any]]:
    """'<user>#<n>' -> {user_id, request_ids, tracks:[{track_id, profile_id, roles, names}]}."""
    per_user: dict[Any, dict[tuple[str, str], dict[str, Any]]] = {}
    for r in rows:
        tid, pid = str(r.get("trackId") or ""), str(r.get("profileId") or "")
        if not tid or not pid:
            continue
        t = per_user.setdefault(r.get("userId"), {}).setdefault((tid, pid), {
            "track_id": tid, "profile_id": pid, "roles": [], "names": names_of(r, builder.profile_doc(pid)),
            "request_ids": []})
        t["roles"] = list(dict.fromkeys(t["roles"] + [str(c) for c in (r.get("credits") or []) if c]))
        t["request_ids"].append(str(r.get("id")))
    out: dict[str, dict[str, Any]] = {}
    for uid, tracks in per_user.items():
        tl = list(tracks.values())
        for i in range(0, len(tl), GROUP_TRACKS):
            chunk = tl[i:i + GROUP_TRACKS]
            out[f"{uid}#{i // GROUP_TRACKS}"] = {
                "user_id": uid if isinstance(uid, int) else None,
                "request_ids": [rid for t in chunk for rid in t["request_ids"]],
                "tracks": [{k: t[k] for k in ("track_id", "profile_id", "roles", "names")} for t in chunk]}
    return out


def _batches(items: list[Any], n: int) -> list[list[Any]]:
    return [items[i:i + n] for i in range(0, len(items), n)]


def submit(store: Store, deps: Deps, *, max_requests: int = 300, max_pages: int = 20,  # noqa: ARG001
           only: set[str] | None = None) -> Stats:
    """`only`: restrict to these credit request ids (a tray's rows), still read from core as pending."""
    st = Stats(new_run_id("submit"), "submit")
    store.start_run(st.run_id, "submit")
    try:
        if deps.select is None:
            raise RuntimeError("no request selector (Deps.select): the admin list is never paged unscoped")
        statuses = TRAY_STATUSES if only is not None else ("unverified",)
        skip = store.requests_with_open_capture() | store.requests_verified_since(
            (deps.now() - REVERIFY_AFTER).strftime("%Y-%m-%dT%H:%M:%SZ"))
        limit = max_requests if only is None else min(max_requests, len(only))
        seen = store.requests_with_any_verdict()
        rows = order(pending_requests(deps.admin, deps.select, statuses, only, limit, skip, deps.paying, seen),
                     deps.paying)
        if only is not None:
            rows = [r for r in rows if str(r.get("id")).lower() in only]
        rows = [r for r in rows if str(r.get("id")).lower() not in {x.lower() for x in skip}][:max_requests]
        st.requests = len(rows)
        builder = EvidenceBuilder(deps.admin, now=deps.now())
        groups = groups_for(rows, builder)
        keys = list(groups)

        def one(batch: list[str]) -> list[tuple[str, dict[str, Any]]]:
            items = [{"key": k, "tracks": [{"track_id": t["track_id"], "profile_id": t["profile_id"]}
                                           for t in groups[k]["tracks"]]} for k in batch]
            try:
                ans = {a.get("key"): a for a in deps.capture("submit", items)}
            except Exception as exc:  # noqa: BLE001 - recorded per group, retried next run
                return [(k, {"key": k, "error": f"{type(exc).__name__}: {str(exc)[:240]}"}) for k in batch]
            return [(k, ans.get(k) or {"key": k, "error": "no answer for this key"}) for k in batch]

        with ThreadPoolExecutor(4) as ex:
            for res in ex.map(one, _batches(keys, EXEC_BATCH)):
                for k, a in res:
                    a = {**a, "statuses": list(statuses)}
                    g = groups[k]
                    store.add_capture(st.run_id, k, g["user_id"], g["request_ids"], g["tracks"], a)
                    st.groups += 1
                    if a.get("error"):
                        st.errors.append(f"{k}: {a['error']}")
    finally:
        store.finish_run(st.run_id, st.as_dict())
    deps.log("submit " + json.dumps(st.as_dict()))
    return st


# ── packets ──────────────────────────────────────────────────────────────────
def profile_type(doc: dict[str, Any] | None) -> str | None:
    t = str((doc or {}).get("type") or (doc or {}).get("profileType") or "").lower()
    if not t:
        return None
    return "organization" if any(k in t for k in ("org", "company", "label", "publisher")) else "person"


def label_strings(req: dict[str, Any], track_doc: dict[str, Any] | None) -> list[dict[str, Any]]:
    out = []
    meta = req.get("metadata") if isinstance(req.get("metadata"), dict) else {}
    for kind, val in (("core_label", meta.get("label")),
                      ("track_label", (track_doc or {}).get("label")),
                      ("release_copyright_p", (track_doc or {}).get("copyrightP") or (track_doc or {}).get("pLine")),
                      ("release_copyright_c", (track_doc or {}).get("copyrightC") or (track_doc or {}).get("cLine"))):
        if isinstance(val, str) and val.strip():
            out.append({"kind": kind, "string": val.strip()[:200]})
    return out


DUP_PAGES = 10                    # approved requests read per profile before the set is "unknown"
DUP_UNKNOWN = "unknown"


class Duplicates:
    """Approved requests per profile, read in full (paginated) once per run. A failed or
    truncated read is UNKNOWN, and an unknown duplicate check blocks approval (QA @274a979)."""

    def __init__(self, admin: admin_api.Admin):
        self.admin = admin
        self.seen: dict[str, list[dict[str, Any]] | None] = {}

    def _approved(self, pid: str) -> list[dict[str, Any]] | None:
        rows: list[dict[str, Any]] = []
        try:
            for page in range(1, DUP_PAGES + 1):
                items = admin_api.list_requests(self.admin, status="approved", limit=500, page=page,
                                                profile_ids=[pid])
                rows += items
                if len(items) < 500:
                    return rows
        except admin_api.AdminError:
            return None
        return None                       # still full after DUP_PAGES pages: not exhaustive

    def of(self, req: dict[str, Any]) -> str | None:
        """The approved duplicate's id, None when there is none, DUP_UNKNOWN when unreadable."""
        pid, tid = str(req.get("profileId") or ""), str(req.get("trackId") or "")
        if not pid or not tid:
            return DUP_UNKNOWN
        if pid not in self.seen:
            self.seen[pid] = self._approved(pid)
        approved = self.seen[pid]
        if approved is None:
            return DUP_UNKNOWN
        fams = {family_of(c) for c in (req.get("credits") or []) if c}
        covered: set[str] = set()
        ids = []
        for a in approved:
            if str(a.get("trackId") or "") == tid and str(a.get("id")) != str(req.get("id")) \
                    and a.get("userId") == req.get("userId"):
                covered |= {family_of(c) for c in (a.get("credits") or []) if c}
                ids.append(str(a.get("id")))
        return ids[0] if fams and ids and fams <= covered else None


def _track_doc(builder: EvidenceBuilder, tid: str) -> dict[str, Any] | None:
    """The admin track document (label / P-line fields), one GET per track per run."""
    if not tid:
        return None
    cache: dict[str, dict[str, Any] | None] = builder.__dict__.setdefault("_dsp_track_docs", {})
    if tid not in cache:
        try:
            cache[tid] = builder._reread(admin_api.track, tid)
        except admin_api.AdminError:
            cache[tid] = None
    return cache[tid]


def build_packet(req: dict[str, Any], capture: dict[str, Any] | None, builder: EvidenceBuilder, deps: Deps,
                 dups: Duplicates, idp_hold_ids: list[str] | None = None) -> dict[str, Any]:
    pid, tid = str(req.get("profileId") or ""), str(req.get("trackId") or "")
    uid = req.get("userId") if isinstance(req.get("userId"), int) and not isinstance(req.get("userId"), bool) else None
    doc = builder.profile_doc(pid) if pid else None
    cat, _err = builder.track_catalog(tid)
    track_doc = _track_doc(builder, tid)
    g = deps.gate(uid)
    gate = {"decision": g.decision, "band": (g.payload or {}).get("band"), "reasons": list(g.reasons)[:6]}
    return {
        "request_id": str(req.get("id") or ""),
        "user_id": uid,
        "profile_id": pid,
        "profile_name": (doc or {}).get("name") or (req.get("profile") or {}).get("name"),
        "profile_type": profile_type(doc),
        "track_id": tid,
        "track_title": req.get("spotifyTrackTitle"),
        # ISRC as the CATALOG holds it (raw DSP recordings, read by the pod), never the request's own
        # metadata, which the claimant's client can set; core's metadata ISRC is kept for comparison.
        "isrcs": sorted({str(x.get("isrc")) for x in ((capture or {}).get("recording_facts") or {}).get("isrcs") or []
                         if x.get("isrc")}),
        "request_isrc": (req.get("metadata") or {}).get("isrc") if isinstance(req.get("metadata"), dict) else None,
        "recording_facts": (capture or {}).get("recording_facts"),
        "created_at": req.get("createdAt"),
        "roles": [str(c) for c in (req.get("credits") or []) if c],
        "popularity": cat.popularity,
        "artist_popularity": cat.artist_popularity if cat.artists_known else None,
        "artists_known": cat.artists_known,
        "profile_credit_count": (doc or {}).get("creditCount"),
        # Missing / malformed stays None: the rules read it as "validator findings unknown" (QA @8487d4f).
        "verification_data": req.get("verificationData") if isinstance(req.get("verificationData"), dict) else None,
        "name_collisions": (capture or {}).get("name_collisions"),
        "label_strings": label_strings(req, track_doc),
        "org_claim_processed": deps.org_claim(uid, pid) if profile_type(doc) == "organization" else None,
        "capture": capture,
        "gate": gate,
        # Every guard is an explicit bool or None (unknown, which blocks approval): QA @dfe29fd.
        "flags": {"deny_user": None if uid is None else uid in deps.deny_user_ids,
                  "deny_profile": pid.lower() in deps.deny_profile_ids if pid else None,
                  "watchlist": None if deps.watch_user_ids is None else
                  (uid in deps.watch_user_ids or pid.lower() in (deps.watch_profile_ids or frozenset())),
                  "idp_hold": None if idp_hold_ids is None or uid is None else str(uid) in set(idp_hold_ids)},
        **_dup_fields(dups.of(req)),
    }


def _dup_fields(dup: str | None) -> dict[str, Any]:
    if dup == DUP_UNKNOWN:
        return {"duplicate_of": None, "duplicate_unknown": True}
    return {"duplicate_of": dup, "duplicate_unknown": False}


def capture_for_request(read_row: dict[str, Any], cap: dict[str, Any], req: dict[str, Any]) -> dict[str, Any]:
    key = f"{req.get('trackId') or ''}|{req.get('profileId') or ''}"
    tr = (read_row.get("tracks") or {}).get(key) or {}
    roles = tr.get("roles") or {}
    return {"request_id": cap["capture_request_id"], "requested_at": cap["requested_at"],
            "read_at": utcnow(), "person_name": tr.get("person_name"), "name_collisions": tr.get("name_collisions"),
            "recording_facts": tr.get("recording_facts"),
            "roles": {str(c): roles.get(str(c)) or {} for c in (req.get("credits") or []) if c}}


def still_pending(admin: admin_api.Admin, cap: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """The capture's credit requests in the statuses it was filed for (open only by default; a tray run
    records approved too, so a request another lane decided meanwhile is not verified), re-read now
    through one scoped read per track. Only the capture's own request ids count."""
    want = {str(x).lower() for x in json.loads(cap["request_ids_json"])}
    cap_statuses = tuple(json.loads(cap.get("submit_json") or "{}").get("statuses") or OPEN_STATUSES)
    scopes = sorted({("track", t["track_id"]) for t in json.loads(cap["tracks_json"]) if t.get("track_id")})
    return _scoped_reads(admin, scopes, cap_statuses, want, 5)


def _waiting(read_row: dict[str, Any]) -> bool:
    return any(s.get("state") == "WAITING" for t in (read_row.get("tracks") or {}).values()
               for r in (t.get("roles") or {}).values() for s in ((r or {}).get("sources") or {}).values())


def verify(store: Store, deps: Deps, *, max_groups: int = 200) -> tuple[Stats, list[dict[str, Any]]]:
    st = Stats(new_run_id("verify"), "verify")
    store.start_run(st.run_id, "verify")
    out: list[dict[str, Any]] = []
    try:
        caps = store.open_captures()[:max_groups]
        builder = EvidenceBuilder(deps.admin, now=deps.now())
        dups = Duplicates(deps.admin)
        reads: dict[int, dict[str, Any]] = {}

        def one(batch: list[dict[str, Any]]) -> list[tuple[int, dict[str, Any]]]:
            items = [{"key": c["key"], "request_id": c["capture_request_id"], "requested_at": c["requested_at"],
                      "tracks": json.loads(c["tracks_json"])} for c in batch]
            try:
                ans = {a.get("key"): a for a in deps.capture("read", items)}
            except Exception as exc:  # noqa: BLE001 - the capture stays open, read next run
                return [(c["id"], {"error": f"{type(exc).__name__}: {str(exc)[:240]}"}) for c in batch]
            return [(c["id"], ans.get(c["key"]) or {"error": "no answer for this key"}) for c in batch]

        with ThreadPoolExecutor(4) as ex:
            for res in ex.map(one, _batches(caps, EXEC_BATCH)):
                reads.update(res)
        for cap in caps:
            row = reads.get(cap["id"]) or {"error": "not read"}
            if row.get("error"):
                st.errors.append(f"{cap['key']}: {row['error']}")
                continue
            st.groups += 1
            age = deps.now() - (parse_ts(cap["requested_at"]) or deps.now())
            closed = not _waiting(row) or age > CLOSE_AFTER
            # The capture closes only after every verdict of this read is persisted (QA @274a979): a
            # failed re-read or packet leaves it open, and the next run reads it again.
            try:
                live = still_pending(deps.admin, cap)
            except admin_api.AdminError as exc:
                st.errors.append(f"{cap['key']}: pending re-read failed: {exc}")
                store.record_read(cap["id"], row, False)
                continue
            failed = False
            for rid in json.loads(cap["request_ids_json"]):
                req = live.get(rid)
                if req is None:
                    continue                      # decided or deleted meanwhile: nothing to verify
                try:
                    packet = build_packet(req, capture_for_request(row, cap, req), builder, deps, dups,
                                          row.get("idp_hold_ids"))
                except Exception as exc:  # noqa: BLE001 - recorded; the capture stays open
                    st.errors.append(f"{rid}: packet failed: {type(exc).__name__}: {str(exc)[:160]}")
                    failed = True
                    continue
                v = rules.verify(packet).as_dict()
                paid = None if deps.paying is None else packet["user_id"] in deps.paying
                try:
                    store.add_verdict(st.run_id, v, packet, paid)
                except ValueError as exc:         # oversized evidence: refused, never truncated
                    st.errors.append(f"{rid}: verdict not recorded: {exc}")
                    failed = True
                    continue
                st.requests += 1
                st.verdicts[v["verdict"]] = st.verdicts.get(v["verdict"], 0) + 1
                st.classes[v["reason_class"]] = st.classes.get(v["reason_class"], 0) + 1
                out.append(v)
            store.record_read(cap["id"], row, closed and not failed)
    finally:
        store.finish_run(st.run_id, st.as_dict())
    deps.log("verify " + json.dumps(st.as_dict()))
    return st, out


def verify_packets(packets: list[dict[str, Any]], store: Store | None = None) -> list[dict[str, Any]]:
    """The eval entry point: verdicts for ready-made packets (no network). With a store, logged
    under a `packets` run like any other shadow run."""
    run_id = new_run_id("packets")
    if store:
        store.start_run(run_id, "packets")
    out = []
    for p in packets:
        v = rules.verify(p).as_dict()
        if store:
            store.add_verdict(run_id, v, p, p.get("paid"))
        out.append(v)
    if store:
        store.finish_run(run_id, {"requests": len(out)})
    return out


ORG_CLAIM_SQL = ("SELECT count(*) FROM postgresql_core.public.claiming c WHERE c.userid = {uid} "
                 "AND cast(c.profileid AS varchar) = '{pid}' AND c.status = 'processed' AND c.deletedat IS NULL")


def trino_org_claim(query: Callable[[str], str]) -> Callable[[int | None, str], bool | None]:
    """A cached org-claim lookup over a read-only Trino SELECT; any failure or odd input is None."""
    import re
    cache: dict[tuple[int, str], bool | None] = {}

    def look(uid: int | None, pid: str) -> bool | None:
        if not isinstance(uid, int) or isinstance(uid, bool) or not re.fullmatch(r"[0-9a-fA-F-]{36}", pid or ""):
            return None
        if (uid, pid) not in cache:
            try:
                out = query(ORG_CLAIM_SQL.format(uid=uid, pid=pid.lower()))
                nums = [ln.strip().strip('"') for ln in out.splitlines() if ln.strip().strip('"').isdigit()]
                cache[(uid, pid)] = int(nums[-1]) > 0 if nums else None
            except Exception:  # noqa: BLE001 - unknown, which never anchors
                cache[(uid, pid)] = None
        return cache[(uid, pid)]
    return look


# ── anchor records for an approve tray (Fable ruling l12-approvals-core = A) ────────────────────
def tray_rows(tray: dict[str, Any]) -> list[dict[str, Any]]:
    """The tray's APPROVE rows: tray-level action 'approve', or a row whose own action is approve."""
    rows = tray.get("rows") if isinstance(tray.get("rows"), list) else []
    top = str(tray.get("action") or "").lower()
    out = []
    for r in rows:
        if not isinstance(r, dict) or not r.get("request_id"):
            continue
        if str(r.get("action") or top).lower() == "approve":
            out.append(r)
    return out


def build_anchors(store: Store, tray: dict[str, Any], *, now: datetime | None = None,
                  log: Callable[[str], None] = lambda m: None) -> tuple[Stats, list[dict[str, Any]]]:
    """One anchor record per APPROVE tray row, built ONLY from the verifier's own standing verdict
    and packet for that request (never from the tray). Records are logged to dsp_anchors; nothing
    is written to core here (the core anchor endpoint does not exist yet)."""
    from . import anchor as anchor_mod
    st = Stats(new_run_id("anchors"), "anchors")
    store.start_run(st.run_id, "anchors")
    out: list[dict[str, Any]] = []
    try:
        for row in tray_rows(tray):
            rid = str(row["request_id"]).lower()
            ruling = row.get("ruling_id") or tray.get("ruling_id")
            st.requests += 1
            latest = store.latest_captured_for(rid)
            if latest is None or not latest.get("packet_json"):
                why = ("no verdict from this job's own capture for this request (run submit --tray, then verify); "
                       "verdicts from supplied packets never anchor")
                store.add_anchor(st.run_id, rid, "refused", reason=why, ruling_id=ruling)
                out.append({"request_id": rid, "outcome": "refused", "reason": why})
                st.classes["refused"] = st.classes.get("refused", 0) + 1
                continue
            packet = json.loads(latest["packet_json"])
            verdict = {"verdict": latest["verdict"], "reason_class": latest["reason_class"],
                       "approve_roles": json.loads(latest["approve_roles"] or "[]")}
            try:
                rec = anchor_mod.build(packet, verdict, ruling_id=ruling, now=now)
            except anchor_mod.AnchorRefused as exc:
                store.add_anchor(st.run_id, rid, "refused", reason=str(exc), ruling_id=ruling, verdict_id=latest["id"])
                out.append({"request_id": rid, "outcome": "refused", "reason": str(exc)})
                st.classes["refused"] = st.classes.get("refused", 0) + 1
                continue
            note = None
            tray_roles = [str(x) for x in (row.get("roles") or []) if x]
            if tray_roles and sorted(tray_roles) != sorted(rec["roles"]):
                note = (f"the tray names roles {tray_roles}; the anchor covers {rec['roles']} only "
                        "(role edit before any approval)")
            store.add_anchor(st.run_id, rid, "built", kind=rec["kind"], reason=note, ruling_id=ruling,
                             verdict_id=latest["id"], record=rec)
            out.append({"request_id": rid, "outcome": "built", "kind": rec["kind"], "roles": rec["roles"],
                        "record_sha256": rec["record_sha256"], "note": note})
            st.classes[rec["kind"]] = st.classes.get(rec["kind"], 0) + 1
    finally:
        store.finish_run(st.run_id, st.as_dict())
    log("anchors " + json.dumps(st.as_dict()))
    return st, out
