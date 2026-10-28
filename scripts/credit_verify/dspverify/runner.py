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
def pending_requests(admin: admin_api.Admin, max_pages: int = 20) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for page in range(1, max_pages + 1):
        items = admin_api.list_requests(admin, status="unverified", limit=500, page=page)
        rows += items
        if len(items) < 500:
            break
    return rows


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


def submit(store: Store, deps: Deps, *, max_requests: int = 300, max_pages: int = 20) -> Stats:
    st = Stats(new_run_id("submit"), "submit")
    store.start_run(st.run_id, "submit")
    try:
        rows = order(pending_requests(deps.admin, max_pages), deps.paying)
        skip = store.requests_with_open_capture() | store.requests_verified_since(
            (deps.now() - REVERIFY_AFTER).strftime("%Y-%m-%dT%H:%M:%SZ"))
        rows = [r for r in rows if str(r.get("id")) not in skip][:max_requests]
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
            "roles": {str(c): roles.get(str(c)) or {} for c in (req.get("credits") or []) if c}}


def still_pending(admin: admin_api.Admin, cap: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """The capture's credit requests that are STILL unverified, re-read now (by profile)."""
    pids = sorted({t["profile_id"] for t in json.loads(cap["tracks_json"])})
    out: dict[str, dict[str, Any]] = {}
    for i in range(0, len(pids), 20):
        for page in range(1, 6):
            items = admin_api.list_requests(admin, status="unverified", limit=500, page=page,
                                            profile_ids=pids[i:i + 20])
            out.update({str(r.get("id")): r for r in items})
            if len(items) < 500:
                break
        else:
            # Never read a truncated list as "decided meanwhile": the capture stays open.
            raise admin_api.AdminError(f"unverified list for {len(pids[i:i + 20])} profiles still full after 5 pages")
    return out


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
