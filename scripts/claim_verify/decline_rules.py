"""C6 claim declines as CODE (captain 16:0xZ 2026-10-29: no per-item decision from any Fable seat; per-item decisions
come from deterministic code through the node-8 decider/executor, with audit). Rules: Fable claim-route-zero (A)-(D)
and user-decisions-fable-d2 rules-for-code-1028 sections 2 and 5, as they survived the 1,458-claim pass.

decide(claim, ...) -> Decision(decision, contradiction, rule_id, evidence), deterministic and pure:
  - `decline` ONLY when the claim's own facts CONTRADICT the identity, in one of the executor's classes
    (credit_review.claim_executor.CONTRADICTIONS). A name, a popularity or an absence never declines.
    The big-name rail does NOT block a contradicted decline (claim-route-zero (A)).
  - `hold` when the account is not cleanly allowed (account gate hold / unknown / watchlisted): it goes to the
    tray, never to a decline (claim-route-zero (C)). A fraud-tier account's claims are held, not declined.
  - `none` otherwise (the claim stays on the code / document road).
  - a `created by user` claim is never declined (core's reject publishes a catalog delete; core #11012 refuses it 409).

The contradiction classes, each from facts the export or the live Trino read carries:
  test_account                the signup domain is a test-lab domain, or a muso.ai staff address is typed into the
                              claim's own fields by a non-muso account.
  deceased_self_claim         an artist / professional claim on a profile the catalog-facts list names as deceased.
  contradicted_by_own_claims  one account, >= 2 claims within 7 days on big profiles the CATALOG proves unrelated:
                              0 shared recordings (matvw_profile_credit; shared_tracks_sql). An unknown pair, or any
                              shared recording (a label and its founder's artist profile: G59 / Aristos Petrou share
                              438), never declines.
  individual_claims_company   a `company claim on add` organization claim from a free-mail / Apple-relay address
                              on a MAJOR org (pop >= 80, >= 5,000 credits or a named major / PRO / platform), where
                              the claimant's role is an individual contributor's, or >= 2 other users' claims on
                              that org were already rejected.
build_tray() turns the declines into a claim_executor tray (action reject_claim); the executor re-reads every fact
fresh on core before any write. replay() is the shadow run over the prep exports (no write, ever).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Iterable, Mapping

RULES_VERSION = "c6-decline-rules-v1"
OPEN_STATUSES = ("pending", "reverted")
CREATED_BY_USER = "created by user"
COMPANY_CLAIM = "company claim on add"
BIG_POPULARITY = 80
BIG_CREDITS = 5000
OWN_CLAIMS_WINDOW = timedelta(days=7)
PRIOR_REJECTED_MIN = 2
FREE_MAIL = frozenset({
    "gmail.com", "googlemail.com", "yahoo.com", "yahoo.co.uk", "ymail.com", "hotmail.com", "hotmail.co.uk",
    "outlook.com", "live.com", "msn.com", "icloud.com", "me.com", "mac.com", "aol.com", "gmx.com", "gmx.de",
    "mail.com", "proton.me", "protonmail.com", "yandex.ru", "yandex.com", "mail.ru", "qq.com", "163.com",
    "126.com", "privaterelay.appleid.com", "att.net", "sbcglobal.net", "comcast.net", "verizon.net", "web.de",
    "t-online.de", "rocketmail.com", "libero.it", "orange.fr", "wanadoo.fr", "laposte.net", "naver.com", "daum.net",
    "rediffmail.com", "zoho.com", "tutanota.com", "fastmail.com", "seznam.cz", "wp.pl", "o2.pl", "bol.com.br",
    "uol.com.br", "terra.com.br",
})
# Provider families with a country domain per market (yahoo.com.ar, hotmail.fr, live.it, outlook.de, gmx.at ...).
FREE_MAIL_FAMILIES = re.compile(r"^(yahoo|ymail|hotmail|live|outlook|msn|gmx|aol|icloud|proton|yandex|mail)\.[a-z.]{2,10}$")


def is_free_mail(domain: str) -> bool:
    d = str(domain or "").strip().lower()
    return d in FREE_MAIL or bool(FREE_MAIL_FAMILIES.match(d))
TEST_DOMAINS = frozenset({"cloudtestlabaccounts.com"})
STAFF_ADDRESS = re.compile(r"[a-z0-9._%+-]+@muso\.ai\b", re.I)
INDIVIDUAL_ROLES = frozenset({
    "songwriter", "writer", "composer", "lyricist", "artist", "singer", "rapper", "musician", "producer",
    "engineer", "mixing engineer", "mastering engineer", "recording engineer", "designer", "a&r", "anr",
    "manager", "dj", "other", "beatmaker", "vocalist",
})
# Named majors / PROs / platforms whose catalog popularity understates them (fixture: BMI pop 52, YouTube pop 47).
# A catalog FACT list (who the org is), not a decision list; append by PR.
MAJOR_ORG_NAMES = frozenset({
    "bmi", "ascap", "sesac", "gmr", "socan", "prs", "prsformusic", "gema", "sacem", "jasrac", "youtube",
    "youtubemusic", "spotify", "applemusic", "tiktok", "soundcloud", "universalmusicgroup", "universalmusic",
    "sonymusic", "sonymusicentertainment", "warnermusicgroup", "warnerrecords", "atlanticrecords", "rcarecords",
    "columbiarecords", "interscoperecords", "capitolrecords", "defjam", "republicrecords", "concordmusicgroup",
    "rocnation", "bmgrightsmanagement", "kobalt", "downtownmusic",
})


@dataclass(frozen=True)
class Decision:
    claim_id: int
    decision: str                    # decline | hold | none
    contradiction: str | None
    rule_id: str
    evidence: str


def fold(value: Any) -> str:
    """NFKD, ascii, lowercase, [a-z0-9] only (the watchlist's normalizer)."""
    text = unicodedata.normalize("NFKD", str(value or "")).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]", "", text)


def _ts(value: Any) -> datetime | None:
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


def _links(claim: Mapping[str, Any]) -> dict[str, Any]:
    links = claim.get("verificationLinks")
    return links if isinstance(links, dict) else {}


def _is_big(profile: Mapping[str, Any] | None) -> bool:
    if not profile:
        return False
    pop, credits = profile.get("popularity"), profile.get("creditCount")
    return ((isinstance(pop, (int, float)) and pop >= BIG_POPULARITY)
            or (isinstance(credits, (int, float)) and credits >= BIG_CREDITS)
            or _named_major(profile.get("name")))


LEGAL_WORDS = frozenset({"the", "oy", "oyj", "ab", "ltd", "limited", "inc", "incorporated", "llc", "llp", "gmbh", "ag",
                         "co", "corp", "corporation", "company", "sa", "sas", "sarl", "srl", "spa", "bv", "nv", "plc",
                         "pty", "kk"})


def org_core(name: Any) -> str:
    """Folded org name without a leading 'the' or legal-form words: 'BMI, Inc.' -> 'bmi'."""
    words = [w for w in re.split(r"[^0-9a-z]+", unicodedata.normalize("NFKD", str(name or "")).encode("ascii", "ignore")
                                 .decode().lower()) if w]
    return "".join(w for w in words if w not in LEGAL_WORDS)


def _named_major(name: Any) -> bool:
    """EXACT match of the org's core name to a named major (QA #1506: a prefix let 'Spotify Fan Club' read as Spotify)."""
    return org_core(name) in MAJOR_ORG_NAMES


def _other_rejected(claim: Mapping[str, Any]) -> int:
    """DISTINCT, identified other users whose claim on this profile was rejected (an anonymous row counts for nothing)."""
    me = str(claim.get("userId"))
    users = {str(o.get("userId")) for o in (claim.get("pk_profile_other_claims") or [])
             if isinstance(o, dict) and o.get("status") == "rejected" and o.get("userId") not in (None, "")
             and str(o.get("userId")) != me}
    return len(users)


def _role(claim: Mapping[str, Any]) -> str:
    return re.sub(r"\s+", " ", str(_links(claim).get("role") or "")).strip().lower()


def contradiction_of(claim: Mapping[str, Any], profile: Mapping[str, Any] | None,
                     *, user_claims: Iterable[Mapping[str, Any]] = (),
                     profiles: Mapping[str, Mapping[str, Any]] | None = None,
                     deceased: frozenset[str] = frozenset(),
                     shared_tracks: Mapping[frozenset, int] | None = None) -> tuple[str, str] | None:
    """(class, evidence) when the claim's own facts contradict the identity, else None."""
    shared_tracks = shared_tracks or {}
    profiles = profiles or {}
    domain = str(claim.get("email_domain") or "").strip().lower()
    typed = " ".join(str(v) for v in _links(claim).values() if v)
    name = (profile or {}).get("name") or "?"
    if domain in TEST_DOMAINS:
        return "test_account", f"signup domain {domain} is a test-lab domain; claim on {name}"
    if domain != "muso.ai" and STAFF_ADDRESS.search(typed):
        return "test_account", f"a muso.ai staff address is typed in the claim fields by a {domain or '?'} account; claim on {name}"

    ptype = str(claim.get("profileType") or "")
    if ptype in ("artist", "professional") and str(claim.get("profileId") or "").lower() in deceased:
        return "deceased_self_claim", f"{name} is a deceased artist (catalog facts) claimed as self by user {claim.get('userId')}"

    if _is_big(profile):
        at = _ts(claim.get("createdAt"))
        mine = fold(name)
        for other in user_claims:
            if other.get("id") == claim.get("id") or str(other.get("userId")) != str(claim.get("userId")):
                continue
            if other.get("status") not in ("pending", "reverted", "rejected", "processed"):
                continue
            oat = _ts(other.get("createdAt"))
            opid = str(other.get("profileId") or "").lower()
            op = profiles.get(opid)
            pair = frozenset({str(claim.get("profileId") or "").lower(), opid})
            if (at and oat and abs(at - oat) <= OWN_CLAIMS_WINDOW and _is_big(op) and fold(op.get("name")) != mine
                    and len(pair) == 2 and shared_tracks.get(pair) == 0):     # proven unrelated; unknown never declines
                return ("contradicted_by_own_claims",
                        f"user {claim.get('userId')} claims unrelated big profiles {name} and {op.get('name')} "
                        f"{abs(at - oat).days} d apart, 0 shared recordings (claims {claim.get('id')} / {other.get('id')})")

    if (ptype == "organization" and str(claim.get("reason") or "").strip().lower() == COMPANY_CLAIM
            and is_free_mail(domain) and _is_big(profile)):
        role, rejected = _role(claim), _other_rejected(claim)
        if role in INDIVIDUAL_ROLES or rejected >= PRIOR_REJECTED_MIN:
            why = f"role '{role}'" if role in INDIVIDUAL_ROLES else f"{rejected} other users' claims on it already rejected"
            return ("individual_claims_company",
                    f"company claim on major org {name} from a free-mail ({domain}) address, {why}")
    return None


def decide(claim: Mapping[str, Any], profile: Mapping[str, Any] | None, gate: Mapping[str, Any] | None,
           *, user_claims: Iterable[Mapping[str, Any]] = (), profiles: Mapping[str, Mapping[str, Any]] | None = None,
           deceased: frozenset[str] = frozenset(), shared_tracks: Mapping[frozenset, int] | None = None) -> Decision:
    cid = int(claim.get("id"))
    if str(claim.get("reason") or "").strip().lower() == CREATED_BY_USER:
        return Decision(cid, "none", None, f"{RULES_VERSION}:created_by_user", "a created-by-user claim is never declined")
    if claim.get("status") not in OPEN_STATUSES:
        return Decision(cid, "none", None, f"{RULES_VERSION}:not_open", f"status {claim.get('status')}")
    found = contradiction_of(claim, profile, user_claims=user_claims, profiles=profiles, deceased=deceased,
                             shared_tracks=shared_tracks)
    gate_ok = isinstance(gate, Mapping) and gate.get("decision") == "allow" and not gate.get("watch")
    if not gate_ok:
        why = "no gate read" if not isinstance(gate, Mapping) else f"gate {gate.get('decision')}/{gate.get('band')}{' watchlisted' if gate.get('watch') else ''}"
        return Decision(cid, "hold", found[0] if found else None, f"{RULES_VERSION}:held_account",
                        f"account not cleanly allowed ({why}): tray, never a decline")
    if found:
        return Decision(cid, "decline", found[0], f"{RULES_VERSION}:{found[0]}", found[1])
    return Decision(cid, "none", None, f"{RULES_VERSION}:no_contradiction", "no contradiction class applies")


CLAIM_KEYS = ("id", "userId", "profileId", "profileType", "reason", "status", "createdAt", "email_domain")
PROFILE_KEYS = ("name", "popularity", "creditCount")
GATE_FOR_REPLAY = {"decision": "allow", "watch": False}   # the executor re-reads the gate FRESH before any write


def snapshot(claim: Mapping[str, Any], profile: Mapping[str, Any] | None, *, user_claims: Iterable[Mapping[str, Any]] = (),
             profiles: Mapping[str, Mapping[str, Any]] | None = None, deceased: frozenset[str] = frozenset(),
             shared_tracks: Mapping[frozenset, int] | None = None) -> dict:
    """The exact decide() inputs for one claim, so the executor can RE-RUN the rule (reproduce) on what was decided."""
    profiles, shared_tracks = profiles or {}, shared_tracks or {}
    pid = str(claim.get("profileId") or "").lower()
    links = _links(claim)
    keep = {k: v for k, v in links.items() if k == "role" or (v and STAFF_ADDRESS.search(str(v)))}
    others = [{k: o.get(k) for k in ("id", "userId", "profileId", "status", "createdAt")} for o in user_claims
              if o.get("id") != claim.get("id") and str(o.get("userId")) == str(claim.get("userId"))]
    opids = {str(o.get("profileId") or "").lower() for o in others}
    return {
        "claim": {**{k: claim.get(k) for k in CLAIM_KEYS}, "profileId": pid, "verificationLinks": keep,
                  "pk_profile_other_claims": [{"userId": o.get("userId"), "status": o.get("status")}
                                              for o in (claim.get("pk_profile_other_claims") or []) if isinstance(o, dict)]},
        "profile": {k: (profile or {}).get(k) for k in PROFILE_KEYS},
        "others": others,
        "other_profiles": {q: {k: (profiles.get(q) or {}).get(k) for k in PROFILE_KEYS} for q in sorted(opids) if q},
        "shared": sorted([sorted(pair) + [n] for pair, n in shared_tracks.items() if pid in pair and pair & opids]),
        "deceased": pid in deceased,
    }


def reproduce(snap: Mapping[str, Any]) -> Decision:
    """Re-run the coded rule on a tray row's facts snapshot (the executor's provenance check)."""
    claim = dict(snap["claim"])
    pid = str(claim.get("profileId") or "").lower()
    profiles = {k.lower(): v for k, v in (snap.get("other_profiles") or {}).items()}
    shared = {frozenset({str(a).lower(), str(b).lower()}): int(n) for a, b, n in (snap.get("shared") or [])}
    return decide(claim, snap.get("profile"), GATE_FOR_REPLAY, user_claims=list(snap.get("others") or []),
                  profiles=profiles, deceased=frozenset({pid}) if snap.get("deceased") else frozenset(),
                  shared_tracks=shared)


def build_tray(decisions: Iterable[Decision], claims: Mapping[int, Mapping[str, Any]], *, daily_cap: int = 50,
               snapshots: Mapping[int, dict] | None = None) -> dict:
    """A claim_executor tray (action reject_claim) from the declines. Each row carries its facts snapshot; the
    executor re-runs the rule on it (reproduce) AND re-reads the core facts fresh before any write."""
    rows = []
    for d in decisions:
        if d.decision != "decline":
            continue
        c = claims[d.claim_id]
        snap = (snapshots or {}).get(d.claim_id)
        if snap is None:
            raise ValueError(f"claim {d.claim_id}: no facts snapshot - a tray row must be reproducible")
        rows.append({"claim_id": d.claim_id, "user_id": int(c["userId"]), "profile_id": str(c["profileId"]).lower(),
                     "profile_type": c["profileType"], "ruling_id": d.rule_id, "contradiction": d.contradiction,
                     "evidence": d.evidence, "audit_reason": f"coded rule {d.rule_id} (no per-item ruling)",
                     "facts": snap})
    return {"action": "reject_claim", "rules_version": RULES_VERSION, "daily_cap": daily_cap, "rows": rows}


PROFILE_ID = re.compile(r"^[0-9a-f-]{36}$")


def shared_tracks_sql(profile_ids: Iterable[str]) -> str:
    """Trino SQL: shared recordings per pair of the given catalog profiles (the live relatedness read)."""
    ids = sorted({p.lower() for p in profile_ids if PROFILE_ID.match(str(p).lower())})
    if len(ids) < 2:
        raise ValueError("need >= 2 valid profile ids")
    inlist = ",".join(f"'{p}'" for p in ids)
    return ("WITH t AS (SELECT DISTINCT profile_id, track_id FROM postgresql_catalog.public.matvw_profile_credit "
            f"WHERE profile_id IN ({inlist})), p AS (SELECT DISTINCT profile_id FROM t) "
            "SELECT a.profile_id, b.profile_id, count(t2.track_id) FROM p a JOIN p b ON a.profile_id < b.profile_id "
            "LEFT JOIN t t1 ON t1.profile_id = a.profile_id LEFT JOIN t t2 ON t2.profile_id = b.profile_id "
            "AND t2.track_id = t1.track_id GROUP BY 1, 2")


def candidate_pairs(claims: Iterable[Mapping[str, Any]], profiles: Mapping[str, Mapping[str, Any]]) -> set[frozenset]:
    """Profile pairs the own-claims class must have a relatedness read for: one user, both big, within 7 days."""
    by_user: dict[str, list[Mapping[str, Any]]] = {}
    for c in claims:
        by_user.setdefault(str(c.get("userId")), []).append(c)
    pairs = set()
    for rows in by_user.values():
        for i, a in enumerate(rows):
            for b in rows[i + 1:]:
                pa, pb = str(a.get("profileId") or "").lower(), str(b.get("profileId") or "").lower()
                ta, tb = _ts(a.get("createdAt")), _ts(b.get("createdAt"))
                if (pa and pb and pa != pb and ta and tb and abs(ta - tb) <= OWN_CLAIMS_WINDOW
                        and _is_big(profiles.get(pa)) and _is_big(profiles.get(pb))):
                    pairs.add(frozenset({pa, pb}))
    return pairs


def load_shared_tracks(path: str | None) -> dict[frozenset, int]:
    """[[a, b, n], ...] -> {frozenset({a, b}): n}; a pair absent from the file is UNKNOWN."""
    if not path:
        return {}
    return {frozenset({str(a).lower(), str(b).lower()}): int(n) for a, b, n in json.loads(Path(path).read_text())}


DEFAULT_DECEASED_POLICY = Path(__file__).resolve().parents[2] / "policies" / "catalog-deceased-profiles.json"


def _rows(out: str) -> list[list[str]]:
    import csv
    import io
    return list(csv.reader(io.StringIO("\n".join(line for line in out.splitlines() if line.startswith('"')))))


def _ids_sql(values: Iterable[Any], *, quote: bool) -> str:
    vals = sorted({str(v).lower() for v in values if v not in (None, "")})
    if quote:
        vals = [v for v in vals if PROFILE_ID.match(v)]
        return ",".join(f"'{v}'" for v in vals)
    return ",".join(str(int(v)) for v in vals if str(v).isdigit())


def live_snapshots(claim_ids: Iterable[int], run, *, deceased: frozenset[str] | None = None) -> dict[int, dict]:
    """FRESH, TRUSTED facts for each claim, built from core (claiming + users) and the catalog through Trino, and the
    repo's own deceased policy: the executor re-runs the rule on THESE, never on the tray's snapshot (QA #1506).
    A claim missing from any read is absent from the result (= unreadable, refused by the caller)."""
    ids = _ids_sql(claim_ids, quote=False)
    if not ids:
        return {}
    deceased = load_deceased(str(DEFAULT_DECEASED_POLICY)) if deceased is None else deceased
    claims: dict[int, dict] = {}
    for rec in _rows(run(
            "select cast(c.id as varchar), cast(c.userid as varchar), lower(c.profileid), c.profiletype, "
            "coalesce(c.reason, ''), c.status, coalesce(to_iso8601(c.createdat), ''), "
            "coalesce(lower(split_part(u.email, '@', 2)), ''), coalesce(json_format(c.verificationlinks), '{}') "
            "from postgresql_core.public.claiming c left join postgresql_core.public.users u on u.id = c.userid "
            f"where c.deletedat is null and c.id in ({ids})")):
        if len(rec) != 9:
            raise RuntimeError(f"claims read: {len(rec)} columns, expected 9")
        cid, uid, pid, ptype, reason, status, created, domain, links = rec
        try:
            links_obj = json.loads(links) if links else {}
        except ValueError:
            links_obj = {}
        claims[int(cid)] = {"id": int(cid), "userId": int(uid) if uid.isdigit() else None, "profileId": pid,
                            "profileType": ptype, "reason": reason or None, "status": status,
                            "createdAt": created or None, "email_domain": domain,
                            "verificationLinks": links_obj if isinstance(links_obj, dict) else {},
                            "pk_profile_other_claims": []}
    if not claims:
        return {}
    users = _ids_sql((c["userId"] for c in claims.values()), quote=False)
    pids = _ids_sql((c["profileId"] for c in claims.values()), quote=True)
    others: list[dict] = []
    if users:
        for rec in _rows(run("select cast(id as varchar), cast(userid as varchar), lower(profileid), status, "
                             "coalesce(to_iso8601(createdat), '') from postgresql_core.public.claiming "
                             f"where deletedat is null and userid in ({users})")):
            oid, ouid, opid, ost, ocr = rec
            others.append({"id": int(oid), "userId": int(ouid), "profileId": opid, "status": ost,
                           "createdAt": ocr or None})
    if pids:
        by_profile: dict[str, list[dict]] = {}
        for rec in _rows(run("select lower(profileid), cast(userid as varchar), status from postgresql_core.public.claiming "
                             f"where deletedat is null and lower(profileid) in ({pids})")):
            ppid, puid, pst = rec
            by_profile.setdefault(ppid, []).append({"userId": int(puid) if puid.isdigit() else None, "status": pst})
        for c in claims.values():
            c["pk_profile_other_claims"] = [o for o in by_profile.get(c["profileId"], [])
                                            if str(o["userId"]) != str(c["userId"])]
    all_pids = _ids_sql({c["profileId"] for c in claims.values()} | {o["profileId"] for o in others}, quote=True)
    profiles: dict[str, dict] = {}
    if all_pids:
        for rec in _rows(run("select lower(p.profile_id), p.name, cast(a.popularity as varchar), cast(a.credits_count as varchar) "
                             "from postgresql_catalog.public.catalog_profile p left join "
                             "postgresql_catalog.public.catalog_profile_aggregations a on a.profile_id = p.profile_id "
                             f"where lower(p.profile_id) in ({all_pids})")):
            ppid, name, pop, cc = rec
            profiles[ppid] = {"name": name, "popularity": int(pop) if pop.isdigit() else None,
                              "creditCount": int(cc) if cc.isdigit() else None}
    shared: dict[frozenset, int] = {}
    pairs = candidate_pairs(list(claims.values()) + others, profiles)
    if pairs:
        for a, b, n in _rows(run(shared_tracks_sql(set().union(*pairs)))):
            shared[frozenset({a.lower(), b.lower()})] = int(n)
    out = {}
    for cid, c in claims.items():
        if c["profileId"] not in profiles:
            continue                                   # catalog unreadable for this claim: absent = refused
        out[cid] = snapshot(c, profiles[c["profileId"]], user_claims=others, profiles=profiles, deceased=deceased,
                            shared_tracks=shared)
    return out


def _jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def replay(work_dirs: Iterable[str], deceased: frozenset[str] = frozenset(),
           shared_tracks: Mapping[frozenset, int] | None = None) -> dict:
    """Shadow replay over claims-review-prep work dirs (claims.jsonl, profiles.jsonl, gate.json). Writes nothing."""
    claims, profiles, gates = {}, {}, {}
    for d in work_dirs:
        w = Path(d)
        for c in _jsonl(w / "claims.jsonl"):
            claims[int(c["id"])] = c
        for p in _jsonl(w / "profiles.jsonl"):
            profiles[str(p["id"]).lower()] = p
        gates.update(json.loads((w / "gate.json").read_text()).get("users") or {})
    by_user: dict[str, list[dict]] = {}
    for c in claims.values():
        by_user.setdefault(str(c["userId"]), []).append(c)
    out, snaps = [], {}
    for cid in sorted(claims):
        c = claims[cid]
        prior = list(by_user.get(str(c["userId"]), [])) + [
            {**o, "userId": c["userId"]} for o in (c.get("pk_user_other_claims") or []) if isinstance(o, dict)]
        prof = profiles.get(str(c["profileId"]).lower())
        d = decide(c, prof, gates.get(str(c["userId"])), user_claims=prior, profiles=profiles, deceased=deceased,
                   shared_tracks=shared_tracks)
        out.append(d)
        if d.decision == "decline":
            snaps[cid] = snapshot(c, prof, user_claims=prior, profiles=profiles, deceased=deceased,
                                  shared_tracks=shared_tracks)
    tally: dict[str, int] = {}
    for d in out:
        key = d.decision if d.decision != "decline" else f"decline:{d.contradiction}"
        tally[key] = tally.get(key, 0) + 1
    return {"rules_version": RULES_VERSION, "claims": len(out), "tally": dict(sorted(tally.items())),
            "decisions": [asdict(d) for d in out], "tray": build_tray(out, claims, snapshots=snaps)}


def load_deceased(path: str | None) -> frozenset[str]:
    if not path:
        return frozenset()
    doc = json.loads(Path(path).read_text())
    return frozenset(str(e["profile_id"]).lower() for e in doc.get("entries", []) if e.get("profile_id"))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--replay", nargs="+", required=True, metavar="WORK_DIR")
    ap.add_argument("--deceased", default=str(Path(__file__).resolve().parents[2] / "policies" / "catalog-deceased-profiles.json"))
    ap.add_argument("--shared-tracks", help="[[profile_a, profile_b, shared], ...] from shared_tracks_sql; absent = unknown")
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    rep = replay(a.replay, load_deceased(a.deceased if Path(a.deceased).exists() else None),
                 load_shared_tracks(a.shared_tracks))
    Path(a.out).write_text(json.dumps(rep, indent=1))
    print(json.dumps({"claims": rep["claims"], "tally": rep["tally"], "tray_rows": len(rep["tray"]["rows"])}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
