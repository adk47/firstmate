"""Profile-link proposals (SHADOW): which DSP contributor id belongs on the PRESENTED profile.

Fable [key=profile-link-anchor] (verify-program-lead-fable-l1, 2026-10-30 07:1xZ; p2 07:10Z). V9 (the DSP
evidence verifier, rules.py) cannot read "credited by id" when the presented profile carries no Spotify /
Tidal contributor id. This module reads V9's OWN same-run captures and proposes the link ONLY when it is
unambiguous. It is coded rules over the verifier's store; no model, no clock, no network in the rules.

A proposal never writes core. It is a row in `link_proposals` (mode `shadow`, the only mode), in the
decider family's ledger (/var/lib/hydra/credit-review/ledger.sqlite3), labelled blind by verifier-eval-v1.
The core profile-link route (registered automation, audit-before-write, reversible) is a later PR, after a
24 h shadow with 0 wrong links in >= 100 labelled proposals (or every proposal when fewer).

Input: docs/credit-verification/profile-link-proposals.md and the read contract
(firstmate data/doc-verify-build-b1/x3-read-contract.md). The V9 store is opened READ-ONLY.

Per presented profile P, over every standing WAIT verdict of V9's own verify runs whose packet presents P,
each claimed role x source reading is classified (``observe``):

  LINKED     the reading credits P's linked id (by_linked_id) and no other id under the exact name: P is
             already linked on this DSP. Linked id + a second exact-name id is AMBIGUOUS.
  CANDIDATE  P is not linked on this DSP (helper person_not_linked_on_<dsp>), and exactly ONE raw
             contributor id of this DSP is credited under the claimant's exact folded name, held by no
             Muso catalog profile.
  HELD       that exact-name id is already held by ANOTHER catalog profile: a duplicate profile.
  MISMATCH   P IS linked on this DSP, and the exact name is credited under a different id.
  AMBIGUOUS  two or more different ids carry the exact name in one reading (or Tidal countries disagree).
  NONE       no usable same-run exact-name credit (not captured, stale, no raw id, name not credited).

Then, in this order (the first that applies decides P; nothing below writes core):

  1. any MISMATCH                       -> tray `link_mismatch` (never relink by code)
  2. any HELD (dedupe FIRST)            -> handoff `merge` in the run counts; NO row here (the merge lane,
                                           doc-verify-build-b1's merge_candidate + C7, owns it)
  3. more than one account presents P   -> refused `multiple_accounts`
  4. not a person profile               -> refused `not_person`
  5. common name                        -> refused `common_name`: presented name != the name the capture
                                           matched, a one-token name, or name_collisions not exactly 0
  6. account guards                     -> refused `guard`: gate not allow / red band, or any of watchlist,
                                           deny_user, deny_profile, idp_hold not an explicit False
  7. big name                           -> refused `big_name`: any evidence track popularity >= 60 or
                                           unknown, linked-artist popularity >= 60 or missing (even
                                           with artists_known), or the
                                           profile's credit count >= 200 or unknown
  8. AMBIGUOUS, two different candidate ids for one DSP across P's readings, or one DSP read LINKED in
     one reading and CANDIDATE in another (any role, any verdict)
                                        -> tray `id_conflict`
  9. evidence: an AGREEING track is one where BOTH Spotify and Tidal credit the claimant in ONE verdict's
     same-run capture (each LINKED or CANDIDATE, at least one CANDIDATE); readings of two verdicts are never
     combined. Independent = different track ids, non-empty and
     disjoint ISRC sets, different base titles. Two independent agreeing tracks -> proposal (basis
     two_tracks); one agreeing track + a processed claim of P by the same account -> proposal (basis
     track_plus_claim); else refused `single_dsp` (a candidate, never on both DSPs) or `one_track`.

One proposal row per DSP that carries a CANDIDATE (Spotify and Tidal ids are different namespaces; the
partner id of the same run is recorded on each row). Never on a name alone: every proposal is a raw
contributor id that the DSP itself credits on the claimant's own claimed track, in this job's capture.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Callable, Iterable

from credit_review.roles import fold

from . import VERSION

RULE_VERSION = "link-1"
KIND_PROPOSAL, KIND_TRAY = "link_proposal", "link_tray"
SOURCES = ("spotify", "tidal")
BIG_POPULARITY = 60            # Fable [key=profile-link-anchor]: big-name (pop >= 60) never auto-links
BIG_PROFILE_CREDITS = 200      # rules.BIG_PROFILE_CREDITS: the verifier's big-profile line

LINKED, CANDIDATE, HELD, MISMATCH, AMBIGUOUS, NONE = "linked", "candidate", "held", "mismatch", "ambiguous", "none"

DEFAULT_LEDGER = os.environ.get("CREDIT_REVIEW_LEDGER", "/var/lib/hydra/credit-review/ledger.sqlite3")

SCHEMA = """
CREATE TABLE IF NOT EXISTS link_proposals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  decided_at TEXT NOT NULL,
  kind TEXT NOT NULL,                  -- link_proposal | link_tray
  mode TEXT NOT NULL DEFAULT 'shadow', -- the only mode: nothing reads this to write core
  rule_version TEXT NOT NULL,
  dsp_version TEXT NOT NULL,           -- the V9 verdict version read
  profile_id TEXT NOT NULL,
  profile_name TEXT,
  user_id INTEGER,
  dsp TEXT NOT NULL DEFAULT '',        -- spotify | tidal ('' on a tray row)
  contributor_id TEXT NOT NULL DEFAULT '',   -- 'spotify:<id>' / 'tidal:<id>' ('' on a tray row)
  partner_contributor_id TEXT,         -- the other DSP's id proposed in the same run, if any
  reason TEXT NOT NULL,                -- basis (two_tracks | track_plus_claim) or the tray class
  confidence REAL,
  request_ids TEXT NOT NULL,           -- JSON
  verdict_ids TEXT NOT NULL,           -- JSON: dsp_verdicts ids the evidence came from
  evidence_json TEXT NOT NULL,         -- per evidence track: ids, title, ISRCs, roles, per-DSP credit + capture
  evidence_sha256 TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS link_proposals_once
  ON link_proposals(kind, rule_version, profile_id, dsp, contributor_id, reason);
CREATE INDEX IF NOT EXISTS link_proposals_profile ON link_proposals(profile_id);
CREATE TABLE IF NOT EXISTS link_runs (
  run_id TEXT PRIMARY KEY,
  started_at TEXT NOT NULL,
  finished_at TEXT,
  rule_version TEXT NOT NULL,
  counts_json TEXT
);
CREATE TRIGGER IF NOT EXISTS link_proposals_no_update BEFORE UPDATE ON link_proposals
BEGIN SELECT RAISE(ABORT, 'link_proposals is append-only'); END;
CREATE TRIGGER IF NOT EXISTS link_proposals_no_delete BEFORE DELETE ON link_proposals
BEGIN SELECT RAISE(ABORT, 'link_proposals is append-only'); END;
CREATE TRIGGER IF NOT EXISTS link_proposals_shadow_only BEFORE INSERT ON link_proposals WHEN NEW.mode != 'shadow'
BEGIN SELECT RAISE(ABORT, 'link_proposals is shadow-only'); END;
"""


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _ts(v: Any) -> datetime | None:
    if not isinstance(v, str) or not v:
        return None
    try:
        t = datetime.fromisoformat(v.replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


def _int(v: Any) -> int | None:
    return v if isinstance(v, int) and not isinstance(v, bool) else None


# ── read V9's store (read-only) ─────────────────────────────────────────────────
def open_ro(path: str) -> sqlite3.Connection:
    """The V9 store READ-ONLY (x3 read contract). A missing store is an error, never 'no candidates'."""
    if not os.path.exists(path):
        raise FileNotFoundError(f"dsp-verify store missing: {path}")
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=60)
    db.row_factory = sqlite3.Row
    return db


def own_captured_verdicts(db: sqlite3.Connection, version: str = VERSION) -> list[dict[str, Any]]:
    """Per request, the latest verdict of a `verify` run of THIS version whose packet names a capture this
    store filed for that request (Store.latest_captured_for, for every request at once). Supplied-packet
    verdicts (verify-packets --log, eval) never qualify; a NULL packet never qualifies."""
    rows = db.execute(
        "SELECT v.* FROM dsp_verdicts v JOIN (SELECT v2.request_id, MAX(v2.id) id FROM dsp_verdicts v2"
        " JOIN dsp_runs r ON r.run_id = v2.run_id WHERE v2.version = ? AND r.kind = 'verify'"
        " GROUP BY v2.request_id) l ON l.id = v.id ORDER BY v.id", (version,)).fetchall()
    caps: dict[str, set[str]] = {}
    for c in db.execute("SELECT capture_request_id, request_ids_json FROM dsp_captures"
                        " WHERE capture_request_id IS NOT NULL"):
        caps.setdefault(str(c[0]), set()).update(str(x).lower() for x in json.loads(c[1] or "[]"))
    out = []
    for r in rows:
        v = dict(r)
        cap = v.get("capture_request_id")
        if not cap or not v.get("packet_json") or str(v["request_id"]).lower() not in caps.get(str(cap), set()):
            continue
        try:
            packet = json.loads(v["packet_json"])
        except ValueError:
            continue
        if not isinstance(packet, dict) or (packet.get("capture") or {}).get("request_id") != cap:
            continue
        v["packet"] = packet
        out.append(v)
    return out


# ── one reading ─────────────────────────────────────────────────────────────────
@dataclass(frozen=True)
class Obs:
    status: str
    contributor_id: str | None = None
    holder: str | None = None              # the catalog profile already holding the id
    credit: str | None = None              # the DSP's role string
    captured_at: str | None = None
    capture_ids: tuple[str, ...] = ()
    why: str = ""


def _observe_one(source: str, rd: Any, requested_at: datetime | None, name: str, profile_id: str) -> Obs:
    if not isinstance(rd, dict):
        return Obs(NONE, why="not read")
    if str(rd.get("state") or "") != "CAPTURED":
        return Obs(NONE, why=f"state {str(rd.get('state') or 'missing').lower()}")
    captured = _ts(rd.get("captured_at"))
    if captured is None or requested_at is None or not captured > requested_at:
        return Obs(NONE, why="not captured after this run's request (same run only)")
    base = dict(captured_at=rd.get("captured_at"), capture_ids=tuple(str(x) for x in (rd.get("capture_ids") or [])[:6]))
    entries = [c for c in (rd.get("credited_in_family") or []) if isinstance(c, (list, tuple)) and len(c) >= 3]
    linked = [c for c in entries if c[2] is True]
    linked_ids = {str(c[3]) for c in linked if len(c) > 3 and c[3]}
    exact = [c for c in entries if c[2] is not True and name and fold(str(c[0] or "")) == name]
    with_id = [c for c in exact if len(c) > 3 and isinstance(c[3], str) and c[3].startswith(f"{source}:")
               and len(c[3]) > len(source) + 1 and c[3] not in linked_ids]
    if linked:
        # Every exact-name id is examined BEFORE a linked credit is accepted (QA @469c0eb0): the linked id plus a
        # second id under the claimant's exact name is two contributor pages for one name, never "linked".
        if with_id:
            ids = sorted({str(c[3]) for c in with_id})
            return Obs(AMBIGUOUS, why=f"credited under the linked id AND the exact name under {', '.join(ids)}",
                       **base)
        return Obs(LINKED, why="credited under the profile's linked id", **base)
    if not with_id:
        return Obs(NONE, why="the claimant's exact name is not credited under a contributor id", **base)
    ids = sorted({str(c[3]) for c in with_id})
    if len(ids) > 1:
        return Obs(AMBIGUOUS, why=f"{len(ids)} {source} ids credit the claimant's exact name: {', '.join(ids)}",
                   **base)
    cid = ids[0]
    holders = sorted({str(c[4]) for c in with_id if len(c) > 4 and c[4]})
    credit = ", ".join(sorted({str(c[1]) for c in with_id if c[1]}))
    holder = holders[0] if len(holders) == 1 else None
    if len(holders) > 1:
        return Obs(AMBIGUOUS, cid, why=f"{cid} is held by {len(holders)} catalog profiles", **base)
    reason = str(rd.get("helper_reason") or "")
    if not reason.startswith(f"person_not_linked_on_{source}"):
        # The presented profile IS linked on this DSP and its id is not credited; the exact name is, under
        # another id. Code never relinks.
        return Obs(MISMATCH, cid, holder, credit, why=f"profile linked on {source}; the exact name is credited "
                   f"under {cid}", **base)
    if holder and holder.lower() != profile_id.lower():
        return Obs(HELD, cid, holder, credit, why=f"{cid} already held by catalog profile {holder}", **base)
    if holder:
        return Obs(LINKED, cid, holder, credit, why="the catalog already holds this id on the presented profile",
                   **base)
    return Obs(CANDIDATE, cid, None, credit, why=f"{cid} credits the claimant's exact name; held by no profile",
               **base)


def observe(source: str, rd: Any, requested_at: datetime | None, name: str, profile_id: str) -> Obs:
    """One role x source reading. Tidal read per country: the countries that say something must agree."""
    countries = rd.get("countries") if isinstance(rd, dict) and isinstance(rd.get("countries"), dict) else None
    if not countries:
        return _observe_one(source, rd, requested_at, name, profile_id)
    per = [_observe_one(source, r, requested_at, name, profile_id) for _, r in sorted(countries.items())]
    said = [o for o in per if o.status != NONE]
    if not said:
        return Obs(NONE, why=f"no {source} country credits the claimant's exact name")
    if len({(o.status, o.contributor_id, o.holder) for o in said}) == 1:
        return said[0]
    return Obs(AMBIGUOUS, why=f"{source} countries disagree: " + "; ".join(sorted({o.why for o in said}))[:300])


# ── one presented profile ───────────────────────────────────────────────────────
@dataclass
class Track:
    """One claimed track as ONE verdict (one same-run capture) read it."""
    track_id: str
    title: str
    isrcs: frozenset[str]
    request_ids: set[str] = field(default_factory=set)
    verdict_ids: set[int] = field(default_factory=set)
    roles: set[str] = field(default_factory=set)
    obs: dict[str, list[Obs]] = field(default_factory=lambda: {s: [] for s in SOURCES})
    capture_request_ids: set[str] = field(default_factory=set)

    def state(self, source: str) -> Obs:
        """The track's state on one DSP over every claimed role: a candidate id wins over a linked credit
        (both say 'credited'), NONE only when no role says anything."""
        said = [o for o in self.obs[source] if o.status != NONE]
        cands = [o for o in said if o.status == CANDIDATE]
        if cands:
            return cands[0]
        if said:
            return said[0]
        return self.obs[source][0] if self.obs[source] else Obs(NONE, why="no claimed role read on this DSP")

    def agrees(self) -> bool:
        st = [self.state(s).status for s in SOURCES]
        return all(x in (LINKED, CANDIDATE) for x in st) and CANDIDATE in st

    def as_evidence(self) -> dict[str, Any]:
        out: dict[str, Any] = {"track_id": self.track_id, "title": self.title, "isrcs": sorted(self.isrcs),
                               "roles": sorted(self.roles), "request_ids": sorted(self.request_ids),
                               "verdict_ids": sorted(self.verdict_ids),
                               "capture_request_ids": sorted(self.capture_request_ids)}
        for s in SOURCES:
            o = self.state(s)
            out[s] = {"state": o.status, "contributor_id": o.contributor_id, "credit": o.credit,
                      "captured_at": o.captured_at, "capture_ids": list(o.capture_ids), "why": o.why}
        return out


@dataclass
class Outcome:
    profile_id: str
    result: str                   # proposal | tray | handoff_merge | refused
    reason: str
    profile_name: str | None = None
    user_id: int | None = None
    request_ids: list[str] = field(default_factory=list)
    verdict_ids: list[int] = field(default_factory=list)
    proposals: list[dict[str, Any]] = field(default_factory=list)   # {dsp, contributor_id, partner}
    confidence: float | None = None
    evidence: list[dict[str, Any]] = field(default_factory=list)
    detail: dict[str, Any] = field(default_factory=dict)


_PAREN = re.compile(r"[\(\[].*?[\)\]]|\s-\s.*$")


def base_title(title: str) -> str:
    """'Song (Remix)' / 'Song - Live' -> 'song': versions of one song are not independent evidence."""
    return fold(_PAREN.sub(" ", title or ""))


def independent_tracks(tracks: list[Track]) -> list[Track]:
    """A set of pairwise independent tracks: different track ids, non-empty disjoint ISRC sets, different base
    titles. A track without catalog ISRCs is never independent evidence.

    EVERY track is tried as the seed (QA @fd852612: one first-fit pass could pick a track that blocks two others
    which are independent of each other), each seed is extended deterministically, and the largest set wins. If
    any independent pair (a, b) exists, the pass seeded at a adds b or another track independent of a, so a
    qualifying pair is always found; the size above 2 only sets the confidence (0.9 vs 0.95), where an
    under-count is the conservative direction."""
    pool = sorted((t for t in tracks if t.isrcs and base_title(t.title)),
                  key=lambda t: (t.track_id, min(t.verdict_ids, default=0)))
    titles = [base_title(t.title) for t in pool]
    n = len(pool)
    ok = [[i != j and pool[i].track_id != pool[j].track_id and not (pool[i].isrcs & pool[j].isrcs)
           and titles[i] != titles[j] for j in range(n)] for i in range(n)]
    bound = len(set(titles))           # no set can hold two tracks of one base title
    best: list[int] = []
    for i in range(n):
        picked = [i]
        for k in range(n):
            if all(ok[k][x] for x in picked):
                picked.append(k)
        if len(picked) > len(best):
            best = picked
            if len(best) >= bound:
                break
    return [pool[x] for x in best]


def _guard_reasons(p: dict[str, Any]) -> list[str]:
    out = []
    gate = p.get("gate") if isinstance(p.get("gate"), dict) else None
    if gate is None or gate.get("decision") != "allow":
        out.append(f"gate_{(gate or {}).get('decision') or 'unknown'}")
    elif str(gate.get("band") or "").lower() == "red":
        out.append("gate_red_band")
    flags = p.get("flags") if isinstance(p.get("flags"), dict) else {}
    for k in ("watchlist", "deny_user", "deny_profile", "idp_hold"):
        if flags.get(k) is not False:
            out.append(f"flag_{k}_{'set' if flags.get(k) is True else 'unknown'}")
    return out


def _big_reasons(p: dict[str, Any]) -> list[str]:
    out = []
    pop = p.get("popularity")
    if not isinstance(pop, (int, float)) or isinstance(pop, bool):
        out.append("track popularity unknown")
    elif pop >= BIG_POPULARITY:
        out.append(f"track popularity {pop}")
    apop = p.get("artist_popularity")
    if isinstance(apop, (int, float)) and not isinstance(apop, bool):
        if apop >= BIG_POPULARITY:
            out.append(f"artist popularity {apop}")
    else:
        # Missing / non-numeric = unknown = big, even with artists_known (a track with no linked artist read as
        # popular-unknown; QA @03870cdb). V9's own "no linked artist" exemption does not carry over to a link.
        out.append("artist popularity unknown")
    cc = _int(p.get("profile_credit_count"))
    if cc is None:
        out.append("profile credit count unknown")
    elif cc >= BIG_PROFILE_CREDITS:
        out.append(f"profile credit count {cc}")
    return out


def _name_reasons(p: dict[str, Any]) -> list[str]:
    name = fold(str(p.get("profile_name") or ""))
    out = []
    if not name:
        out.append("presented profile name missing")
    elif fold(str((p.get("capture") or {}).get("person_name") or "")) != name:
        out.append("the capture matched a name other than the presented profile's")
    elif len(name.split()) < 2:
        out.append("one-token name")
    nc = p.get("name_collisions")
    if nc is None:
        nc = (p.get("capture") or {}).get("name_collisions")
    nc = _int(nc)
    if nc is None or nc < 0:
        out.append("name collisions unknown (unknown = common)")
    elif nc > 0:
        out.append(f"{nc} other catalog profiles share the name")
    return out


def decide_profile(profile_id: str, verdicts: list[dict[str, Any]],
                   claim_lookup: Callable[[int | None, str], bool | None] | None = None) -> Outcome:
    """The whole rule for one presented profile, over its standing own-capture WAIT verdicts."""
    packets = [v["packet"] for v in verdicts]
    names = {fold(str(p.get("profile_name") or "")) for p in packets}
    name = next(iter(names)) if len(names) == 1 else ""
    users = {_int(p.get("user_id")) for p in packets}
    oc = Outcome(profile_id, "refused", "", profile_name=str(packets[0].get("profile_name") or "") or None,
                 user_id=next(iter(users)) if len(users) == 1 else None,
                 request_ids=sorted({str(v["request_id"]) for v in verdicts}),
                 verdict_ids=sorted({int(v["id"]) for v in verdicts}))
    # One evidence unit per VERDICT, i.e. per capture (QA @469c0eb0): Spotify and Tidal agree only inside one
    # same-run capture. Two verdicts on one track (two requests, two runs) are two units; never merged, so a
    # Spotify-only run plus a Tidal-only run can never add up to agreement. Independence still needs two track ids.
    tracks: dict[int, Track] = {}
    for v, p in zip(verdicts, packets):
        cap = p.get("capture") if isinstance(p.get("capture"), dict) else {}
        req_at = _ts(cap.get("requested_at"))
        tid = str(p.get("track_id") or v.get("track_id") or "")
        t = tracks.setdefault(int(v["id"]), Track(tid, str(p.get("track_title") or ""),
                                                  frozenset(str(x) for x in (p.get("isrcs") or []) if x)))
        t.request_ids.add(str(v["request_id"]))
        t.verdict_ids.add(int(v["id"]))
        if cap.get("request_id"):
            t.capture_request_ids.add(str(cap["request_id"]))
        for role, rr in (cap.get("roles") or {}).items():
            srcs = (rr or {}).get("sources") if isinstance(rr, dict) else None
            if not isinstance(srcs, dict):
                continue
            t.roles.add(str(role))
            for s in SOURCES:
                t.obs[s].append(observe(s, srcs.get(s), req_at, name, profile_id))
    all_obs = [o for t in tracks.values() for s in SOURCES for o in t.obs[s]]
    oc.evidence = [t.as_evidence() for t in sorted(tracks.values(), key=lambda t: (t.track_id, min(t.verdict_ids)))]

    mism = [o for o in all_obs if o.status == MISMATCH]
    if mism:
        oc.result, oc.reason = "tray", "link_mismatch"
        oc.detail = {"credited_ids": sorted({o.contributor_id for o in mism if o.contributor_id}),
                     "held_by": sorted({o.holder for o in mism if o.holder})}
        return oc
    held = [o for o in all_obs if o.status == HELD]
    if held:
        oc.result, oc.reason = "handoff_merge", "contributor id held by another profile (duplicate profile)"
        oc.detail = {"held": sorted({(o.contributor_id or "", o.holder or "") for o in held})}
        return oc
    if len(users) != 1 or oc.user_id is None:
        oc.reason = "multiple_accounts" if len(users) > 1 else "user_unknown"
        return oc
    if any(p.get("profile_type") != "person" for p in packets):
        oc.reason = "not_person"
        return oc
    why = sorted({r for p in packets for r in _name_reasons(p)}) + ([] if len(names) == 1 else ["name differs"])
    if why:
        oc.reason, oc.detail = "common_name", {"why": why}
        return oc
    why = sorted({r for p in packets for r in _guard_reasons(p)})
    if why:
        oc.reason, oc.detail = "guard", {"why": why}
        return oc
    why = sorted({r for p in packets for r in _big_reasons(p)})
    if why:
        oc.reason, oc.detail = "big_name", {"why": why}
        return oc
    cand_ids = {s: sorted({o.contributor_id for t in tracks.values() for o in t.obs[s]
                           if o.status == CANDIDATE and o.contributor_id}) for s in SOURCES}
    # One DSP read as LINKED anywhere (any role, any verdict) and as a CANDIDATE anywhere else is a conflict
    # (QA @03870cdb): the profile already has an id there, and the exact name is credited under another.
    linked_and_cand = sorted(s for s in SOURCES if cand_ids[s] and any(
        o.status == LINKED for t in tracks.values() for o in t.obs[s]))
    if any(o.status == AMBIGUOUS for o in all_obs) or any(len(ids) > 1 for ids in cand_ids.values()) \
            or linked_and_cand:
        oc.result, oc.reason = "tray", "id_conflict"
        oc.detail = {"candidate_ids": cand_ids, "linked_and_candidate": linked_and_cand,
                     "ambiguous": sorted({o.why for o in all_obs if o.status == AMBIGUOUS})}
        return oc
    if not any(cand_ids.values()):
        oc.reason = "no_candidate"
        return oc
    agreeing = [t for t in tracks.values() if t.agrees()]
    if not agreeing:
        oc.reason = "single_dsp"
        return oc
    ind = independent_tracks(agreeing)
    if len(ind) >= 2:
        basis, conf = "two_tracks", (0.95 if len(ind) >= 3 else 0.9)
    elif len(ind) == 1 and claim_lookup is not None and claim_lookup(oc.user_id, profile_id) is True:
        basis, conf = "track_plus_claim", 0.85
    else:
        oc.reason = "one_track"
        oc.detail = {"agreeing_tracks": len(agreeing), "independent": len(ind)}
        return oc
    proposed = {s: next((t.state(s).contributor_id for t in ind if t.state(s).status == CANDIDATE), None)
                for s in SOURCES}
    for s in SOURCES:
        if proposed[s]:
            other = next(o for o in SOURCES if o != s)
            oc.proposals.append({"dsp": s, "contributor_id": proposed[s], "partner": proposed[other]})
    oc.result, oc.reason, oc.confidence = "proposal", basis, conf
    oc.evidence = [t.as_evidence() for t in ind]
    oc.detail = {"independent_tracks": len(ind), "agreeing_tracks": len(agreeing)}
    return oc


def decide_all(verdicts: Iterable[dict[str, Any]],
               claim_lookup: Callable[[int | None, str], bool | None] | None = None) -> list[Outcome]:
    """Every presented profile with at least one standing WAIT verdict. APPROVE / DECLINE / DUPLICATE
    verdicts are not link questions."""
    by_profile: dict[str, list[dict[str, Any]]] = {}
    for v in verdicts:
        if v.get("verdict") != "WAIT":
            continue
        pid = str((v.get("packet") or {}).get("profile_id") or v.get("profile_id") or "")
        if pid:
            by_profile.setdefault(pid.lower(), []).append(v)
    return [decide_profile(pid, vs, claim_lookup) for pid, vs in sorted(by_profile.items())]


# ── the shadow ledger (decider family) ────────────────────────────────────────────
def open_ledger(path: str | None = None) -> sqlite3.Connection:
    path = path or DEFAULT_LEDGER
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    db = sqlite3.connect(path, timeout=60)
    db.executescript(SCHEMA)
    return db


def _sha(obj: Any) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True, default=str, ensure_ascii=False).encode()).hexdigest()


def record(db: sqlite3.Connection, run_id: str, outcomes: list[Outcome], *, dsp_version: str = VERSION,
           at: str | None = None) -> dict[str, int]:
    """Append proposal and tray rows. A row already recorded under this rule version (same profile, DSP, id,
    reason) is not written again, so a 24 h of hourly runs labels each proposal once."""
    at = at or utcnow()
    n = {"proposal_rows": 0, "tray_rows": 0, "already_recorded": 0}
    with db:
        for o in outcomes:
            rows = []
            if o.result == "proposal":
                rows = [(KIND_PROPOSAL, p["dsp"], p["contributor_id"], p["partner"]) for p in o.proposals]
            elif o.result == "tray":
                rows = [(KIND_TRAY, "", "", None)]
            ev = {"tracks": o.evidence, "detail": o.detail}
            for kind, dsp, cid, partner in rows:
                cur = db.execute(
                    "INSERT OR IGNORE INTO link_proposals (run_id, decided_at, kind, mode, rule_version, dsp_version,"
                    " profile_id, profile_name, user_id, dsp, contributor_id, partner_contributor_id, reason,"
                    " confidence, request_ids, verdict_ids, evidence_json, evidence_sha256)"
                    " VALUES (?,?,?,'shadow',?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (run_id, at, kind, RULE_VERSION, dsp_version, o.profile_id, o.profile_name, o.user_id, dsp, cid,
                     partner, o.reason, o.confidence, json.dumps(o.request_ids), json.dumps(o.verdict_ids),
                     json.dumps(ev, default=str, ensure_ascii=False), _sha(ev)))
                if cur.rowcount:
                    n["proposal_rows" if kind == KIND_PROPOSAL else "tray_rows"] += 1
                else:
                    n["already_recorded"] += 1
    return n


def counts(outcomes: list[Outcome]) -> dict[str, Any]:
    out: dict[str, Any] = {"profiles": len(outcomes), "by_result": {}, "refused": {}, "tray": {},
                           "handoff_merge": []}
    for o in outcomes:
        out["by_result"][o.result] = out["by_result"].get(o.result, 0) + 1
        if o.result == "refused":
            out["refused"][o.reason] = out["refused"].get(o.reason, 0) + 1
        elif o.result == "tray":
            out["tray"][o.reason] = out["tray"].get(o.reason, 0) + 1
        elif o.result == "handoff_merge":
            # The merge lane's input, never a row here: b1 emits merge_candidate; this list reconciles with it.
            out["handoff_merge"].append({"profile_id": o.profile_id, "request_ids": o.request_ids,
                                         "held": [list(h) for h in o.detail.get("held", [])]})
    return out


def run(dsp_store: str, ledger: str | None = None, *, claim_lookup=None, dry_run: bool = False,
        log: Callable[[str], None] = lambda m: None) -> dict[str, Any]:
    src = open_ro(dsp_store)
    try:
        verdicts = own_captured_verdicts(src)
    finally:
        src.close()
    outcomes = decide_all(verdicts, claim_lookup)
    c = counts(outcomes)
    c["standing_own_capture_verdicts"] = len(verdicts)
    run_id = "link-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:6]
    c["run_id"], c["rule_version"], c["dry_run"] = run_id, RULE_VERSION, dry_run
    if dry_run:
        c["would_write"] = [{"profile_id": o.profile_id, "result": o.result, "reason": o.reason,
                             "proposals": o.proposals} for o in outcomes if o.result in ("proposal", "tray")]
        log(f"dry run: {c['by_result']}")
        return c
    db = open_ledger(ledger)
    try:
        with db:
            db.execute("INSERT INTO link_runs (run_id, started_at, rule_version) VALUES (?,?,?)",
                       (run_id, utcnow(), RULE_VERSION))
        c.update(record(db, run_id, outcomes))
        with db:
            db.execute("UPDATE link_runs SET finished_at=?, counts_json=? WHERE run_id=?",
                       (utcnow(), json.dumps(c, default=str), run_id))
    finally:
        db.close()
    log(f"{run_id}: {c['by_result']} rows +{c['proposal_rows']} proposals +{c['tray_rows']} tray")
    return c


# ── verifier-eval-v1: blind queue + the bar ──────────────────────────────────────
def blind_queue(db: sqlite3.Connection) -> list[dict[str, Any]]:
    """Every shadow proposal WITHOUT the rule's basis or confidence: what a labeller needs to say whether the
    contributor id is this person (profile, DSP id, the tracks + credits it rests on)."""
    out = []
    for r in db.execute("SELECT id, profile_id, profile_name, dsp, contributor_id, evidence_json FROM link_proposals"
                        " WHERE kind=? AND mode='shadow' ORDER BY id", (KIND_PROPOSAL,)):
        ev = json.loads(r[5])
        out.append({"proposal_id": r[0], "profile_id": r[1], "profile_name": r[2], "dsp": r[3],
                    "contributor_id": r[4],
                    "tracks": [{"track_id": t.get("track_id"), "title": t.get("title"), "isrcs": t.get("isrcs"),
                                "credit": (t.get(r[3]) or {}).get("credit")} for t in ev.get("tracks") or []]})
    return out


LABELS = ("correct", "wrong", "unsure")
BAR_MIN = 100
BAR_HOURS = 24


def score(db: sqlite3.Connection, labels: dict[str, str], now: datetime | None = None) -> dict[str, Any]:
    """The bar before any core link route: >= 24 h of shadow, every proposal labelled when fewer than 100
    (else >= 100 labelled), 0 wrong, 0 unsure among the labelled. An unknown label value is an error."""
    bad = {k: v for k, v in labels.items() if v not in LABELS}
    if bad:
        raise ValueError(f"labels must be one of {LABELS}: {sorted(bad.items())[:5]}")
    rows = db.execute("SELECT id, decided_at FROM link_proposals WHERE kind=? AND mode='shadow' ORDER BY id",
                      (KIND_PROPOSAL,)).fetchall()
    ids = {str(r[0]) for r in rows}
    got = {k: v for k, v in labels.items() if k in ids}
    n_wrong = sum(1 for v in got.values() if v == "wrong")
    n_unsure = sum(1 for v in got.values() if v == "unsure")
    first = _ts(rows[0][1]) if rows else None
    hours = ((now or datetime.now(timezone.utc)) - first).total_seconds() / 3600 if first else 0.0
    need = min(BAR_MIN, len(rows))
    met = bool(rows) and hours >= BAR_HOURS and len(got) >= need and n_wrong == 0 and n_unsure == 0
    return {"proposals": len(rows), "labelled": len(got), "wrong": n_wrong, "unsure": n_unsure,
            "unlabelled": len(rows) - len(got), "labels_for_unknown_ids": len(labels) - len(got),
            "shadow_hours": round(hours, 1), "need_labelled": need, "bar_met": met,
            "wrong_ids": sorted(int(k) for k, v in got.items() if v == "wrong")}
